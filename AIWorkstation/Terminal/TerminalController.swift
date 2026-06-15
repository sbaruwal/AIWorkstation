import SwiftUI
import AppKit
import SwiftTerm

/// Decoded process exit, derived from the raw `waitpid` status SwiftTerm reports.
struct ExitStatus: Equatable {
    let code: Int32      // WEXITSTATUS, or -1 if unknown / signaled
    let signal: Int32    // signal number if signaled, else 0

    var signaled: Bool { signal != 0 }
    var isClean: Bool { !signaled && code == 0 }

    var label: String {
        if signaled { return "terminated · signal \(signal)" }
        return "exit \(code)"
    }

    /// Interpret a raw `waitpid` status (or nil for an IO error).
    static func decode(_ raw: Int32?) -> ExitStatus {
        guard let raw else { return ExitStatus(code: -1, signal: 0) }
        let sig = raw & 0x7f
        if sig != 0 { return ExitStatus(code: -1, signal: sig) }
        return ExitStatus(code: (raw >> 8) & 0xff, signal: 0)
    }
}

/// A `LocalProcessTerminalView` that taps raw PTY output so we can derive live
/// agent activity ("● Working" vs "● Waiting/Idle").
///
/// `dataReceived(slice:)` is the only place real process output flows through, and
/// it's delivered on the main queue (SwiftTerm's `LocalProcess` defaults to
/// `DispatchQueue.main`). We must NOT repurpose `terminalDelegate` for this —
/// `LocalProcessTerminalView` sets itself as its own `terminalDelegate` and routes
/// keystrokes (`send`) and process callbacks through it, so overriding it would
/// break input. Subclassing `dataReceived` is the clean, output-only signal and
/// never fires on caret blink (which is a separate CALayer animation).
final class ActivityLocalTerminalView: LocalProcessTerminalView {
    /// Called on the main thread with each chunk of PTY output (byte count).
    var onOutput: ((Int) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?(slice.count)
    }
}

/// Owns one real PTY-backed terminal (SwiftTerm `LocalProcessTerminalView`) and
/// its process lifecycle.
///
/// The terminal view is created once and kept alive here so it survives SwiftUI
/// re-renders (pan / zoom / resize). A live PTY must never be torn down and
/// rebuilt just because the canvas redrew.
final class TerminalController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {

    enum RunState: Equatable {
        case idle                 // created, not yet started
        case preparing            // waiting on an async worktree checkout before launch
        case running
        case exited(ExitStatus)   // process ended
        case needsCLI(AgentKind)  // claude/codex binary could not be located
        case recoverable          // restored from disk — PTY is gone, offer relaunch
    }

    /// Live output activity, derived from PTY data flow. `.working` while bytes are
    /// streaming (e.g. an agent's spinner/output), `.quiet` once output stops.
    enum Activity { case working, quiet }

    let id: UUID
    let kind: AgentKind
    /// Final working directory for the PTY. Mutable because for a worktree launch
    /// the real path isn't known until the (async) `git worktree add` completes —
    /// `finishPreparing` sets it just before the process starts.
    private(set) var workingDirectory: String?
    let terminalView: ActivityLocalTerminalView

    @Published private(set) var runState: RunState = .idle { didSet { refreshStatusStamp() } }
    @Published private(set) var title: String = ""
    /// Whether output is actively flowing right now. Drives the live "Working" dot
    /// and the canvas activity pulse. Flips to `.quiet` after a short idle gap.
    @Published private(set) var activity: Activity = .quiet { didSet { refreshStatusStamp() } }

    /// True when a quiet, running agent appears to be awaiting an answer to a prompt
    /// (a y/n, a menu choice, a permission/trust question) rather than just sitting idle.
    /// Derived by `classifyQuietState()` from the visible terminal tail on each quiet-flip;
    /// drives the `.blocked` status, the attention badge/inbox, and handoff notifications.
    @Published private(set) var needsInput = false {
        didSet {
            refreshStatusStamp()
            // Notify once per DISTINCT unresolved prompt. A TUI redraw flips needsInput
            // false→true for the SAME question (output re-arms the edge), which must not
            // re-notify; `lastNotifiedQuestion` is cleared only when the prompt resolves.
            if needsInput, !oldValue, pendingQuestion != lastNotifiedQuestion {
                lastNotifiedQuestion = pendingQuestion
                onNeedsInput?(pendingQuestion)
            }
        }
    }
    /// The question we last fired a handoff notification for — dedupes redraws of the
    /// same prompt. Cleared in `classifyQuietState` when the screen is no longer blocked.
    private var lastNotifiedQuestion: String?
    /// The question the agent is asking, when `needsInput` — for notifications + inline reply.
    @Published private(set) var pendingQuestion: String?

    /// When the current `displayStatus` VALUE began — drives "waiting 9m" badges. Updated
    /// only on a real status transition (not on every output burst), so the duration
    /// reflects how long the agent has been in *this* state.
    private(set) var statusSince = Date()
    private var lastStampedStatus: SessionStatus = .idle

    /// Re-armed each time output arrives; fires after a quiet gap to flip to `.quiet`.
    private var quietWork: DispatchWorkItem?
    private static let quietGap: TimeInterval = 0.7

    /// Command-bar task. With `autoRunInitialPrompt` it's passed as the CLI's
    /// initial-prompt argument (reliable — the agent runs it as its first message,
    /// even after a trust prompt). Otherwise it's typed into the PTY after launch
    /// for the user to review and submit.
    var initialPrompt: String?
    var autoRunInitialPrompt = true

    /// User-owned free-text CLI flags inserted into the launch (e.g. "--model opus").
    /// Passed through verbatim — the app curates no flags/models (that stays a hard-stop).
    var extraArgs = ""
    /// User-owned extra environment, one `KEY=VALUE` per line/space, merged into the
    /// agent's login environment.
    var extraEnv = ""

    /// Fired when the process ends. `userInitiated` is true when WE killed it (close
    /// / restart), so the notifier can stay quiet for those and only surface
    /// unsolicited finishes/crashes.
    var onExit: ((ExitStatus, _ userInitiated: Bool) -> Void)?
    /// Fired once when launch is blocked because the CLI binary couldn't be located.
    var onNeedsCLI: ((AgentKind) -> Void)?
    /// Fired when a quiet agent starts awaiting an answer to a prompt (false→true), with
    /// the question text — drives handoff notifications. Once per blocked episode.
    var onNeedsInput: ((String?) -> Void)?
    /// Set just before WE terminate the PTY (close/restart) so the resulting exit
    /// isn't reported as an unexpected finish.
    private var userInitiatedExit = false

    private var didStart = false
    /// When the next launch should RESUME the agent's prior CLI session (full history /
    /// context) instead of starting fresh — set by `resumeSession()` on a recovered card.
    private var resumeOnNextLaunch = false
    /// Pending "type the prompt after launch" work (review mode). Held so it can be
    /// cancelled if the session is restarted/terminated before the timer fires.
    private var pendingPrompt: DispatchWorkItem?

    init(id: UUID, kind: AgentKind, workingDirectory: String?, theme: CanvasTheme, recoverable: Bool = false) {
        self.id = id
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.terminalView = ActivityLocalTerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 400))
        super.init()
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] _ in self?.noteActivity() }
        applyTheme(theme)
        // Restored-from-disk sessions don't auto-start; they wait for an explicit
        // Relaunch so we never pretend a dead PTY is still alive.
        if recoverable { runState = .recoverable }
    }

    /// Relaunch a recovered (or any) session FRESH on demand.
    func relaunch() {
        guard runState != .preparing else { return }   // finishPreparing will start it (in the worktree)
        cancelPendingPrompt()
        didStart = false
        runState = .idle
        startIfNeeded()
    }

    /// Relaunch a recovered agent by RESUMING its prior CLI session — `claude --continue`
    /// / `codex resume --last` re-attach the agent to its on-disk conversation (the CLIs
    /// persist sessions per working directory), so the full history and context come back
    /// and the agent re-renders where it left off. Falls back to whatever the CLI does
    /// when no session exists; for a plain shell there's nothing to resume.
    func resumeSession() {
        guard kind != .shell else { return relaunch() }
        resumeOnNextLaunch = true
        relaunch()
    }

    /// Whether resuming the prior session is meaningful for this controller (an agent CLI).
    var canResumeSession: Bool { kind == .claude || kind == .codex }

    /// CLI arguments that resume the most recent session in the working directory.
    /// Confirmed against the installed CLIs (`claude --continue`, `codex resume --last`).
    /// Returned literal (not shell-quoted) — they're flags/subcommands, not a prompt.
    private static func resumeArguments(for kind: AgentKind) -> String? {
        switch kind {
        case .claude: return "--continue"
        case .codex:  return "resume --last"
        case .shell:  return nil
        }
    }

    // MARK: Async worktree preparation

    /// Hold the session in `.preparing` so `startIfNeeded` (called when the card
    /// mounts) won't launch the PTY until the worktree checkout finishes.
    func beginPreparing() {
        runState = .preparing
    }

    /// Worktree checkout is done (or fell back to the repo root). Set the final
    /// working directory and start the process. Runs on the main actor *after* the
    /// synchronous launch code has staged `initialPrompt`, so the prompt is always
    /// in place before the PTY starts.
    func finishPreparing(workingDirectory: String?) {
        self.workingDirectory = workingDirectory
        didStart = false
        runState = .idle
        startIfNeeded()
    }

    // MARK: Lifecycle

    /// Starts the panel's process once. Idempotent.
    ///
    /// Everything launches through the user's *login shell* so PATH / node / env
    /// match a real terminal — essential for the CLIs, which live in PATH entries
    /// a Finder-launched app doesn't inherit. `.shell` runs an interactive login
    /// shell; agents `exec` their CLI (replacing the shell so Ctrl+C / exit and
    /// the process's exit status behave naturally).
    func startIfNeeded() {
        // `.recoverable` waits for an explicit Relaunch; `.preparing` waits for the
        // worktree checkout to finish (`finishPreparing` flips it to `.idle`).
        guard !didStart, runState != .recoverable, runState != .preparing else { return }

        switch kind {
        case .shell:
            launch(shellCommand: nil)
        case .claude, .codex:
            // Confirm the CLI exists before launching, so a missing binary shows
            // a "locate" affordance instead of an opaque exit 127. Launch the exact
            // resolved path so launch always matches detection.
            guard let path = AgentCLI.shared.resolvedPath(for: kind) else {
                runState = .needsCLI(kind)
                onNeedsCLI?(kind)
                return
            }
            var invocation = "exec \(shellQuoted(path))"
            // User-owned flags, verbatim (e.g. "--model opus --verbose"), before the prompt.
            let flags = extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
            if !flags.isEmpty { invocation += " \(flags)" }
            if resumeOnNextLaunch, let resume = Self.resumeArguments(for: kind) {
                // Resume the prior on-disk session (continue the conversation). Takes
                // priority over any staged prompt — we're picking up where it left off,
                // not starting a new task.
                invocation += " \(resume)"
                resumeOnNextLaunch = false
                initialPrompt = nil
            } else if let prompt = initialPrompt, autoRunInitialPrompt {
                // Auto-run: hand the task to the CLI as its initial prompt argument
                // (`claude "<task>"` / `codex "<task>"`) — robust to first-run trust
                // prompts. Review mode leaves it to be typed after launch instead.
                invocation += " \(shellQuoted(prompt))"
                initialPrompt = nil
            }
            launch(shellCommand: invocation)
        }
    }

    private func launch(shellCommand: String?) {
        didStart = true
        // Clear the close/restart suppression flag at the single start chokepoint. On
        // restart, SwiftTerm cancels the child monitor in terminate(), so the old
        // process's `processTerminated` never fires to reset it — without this, the
        // NEXT genuine exit of the restarted session would be wrongly suppressed.
        userInitiatedExit = false
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let cwd = workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path

        // Interactive (`-i`) login (`-l`) shell so .zshrc/.zprofile are sourced —
        // this reproduces the user's real terminal PATH (nvm, ~/.local/bin, brew),
        // which the CLIs need. The environment must carry HOME/USER (the curated
        // SwiftTerm default omits them, which breaks `$HOME`-based PATH setup).
        let args: [String] = shellCommand.map { ["-i", "-l", "-c", $0] } ?? ["-i", "-l"]
        terminalView.startProcess(
            executable: shell,
            args: args,
            environment: loginEnvironment(),
            currentDirectory: cwd
        )
        runState = .running

        // Deliver the command-bar task once the agent has had a moment to start.
        // Cancellable so a restart/terminate before it fires doesn't blindly type
        // the prompt into whatever is now running.
        if let prompt = initialPrompt {
            initialPrompt = nil
            let work = DispatchWorkItem { [weak self] in
                self?.terminalView.send(txt: prompt)
                self?.pendingPrompt = nil
            }
            pendingPrompt = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
        }
    }

    private func cancelPendingPrompt() {
        pendingPrompt?.cancel()
        pendingPrompt = nil
    }

    // MARK: Live activity (derived from PTY output flow)

    /// Output arrived — flip to `.working` and re-arm the quiet timer. Called on the
    /// main thread from the PTY output tap. Publishing only on transition avoids
    /// churn during a fast output burst.
    private func noteActivity() {
        if activity != .working { activity = .working }
        // Output resumed → the agent is no longer parked on a question.
        if needsInput { needsInput = false; pendingQuestion = nil }
        quietWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Classify the now-settled screen BEFORE publishing .quiet so the UI reads a
            // consistent (.quiet + needsInput) pair in one pass.
            self.classifyQuietState()
            self.activity = .quiet
            self.quietWork = nil
        }
        quietWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietGap, execute: work)
    }

    /// Force quiet (process ended / restarted) and stop any pending quiet flip.
    private func resetActivity() {
        quietWork?.cancel()
        quietWork = nil
        if activity != .quiet { activity = .quiet }
        if needsInput { needsInput = false }
        if pendingQuestion != nil { pendingQuestion = nil }
    }

    // MARK: Waiting-reason classifier (blocked-on-a-question vs idle/ready)

    /// On a quiet-flip, read the visible terminal tail to decide whether this agent is
    /// awaiting an answer to a prompt (→ `.blocked`/`needsInput`) vs simply idle/ready.
    /// Reads SwiftTerm's ALREADY-PARSED buffer (`getLine`/`translateToString`) — never
    /// re-emulates ANSI, per the locked constraint.
    private func classifyQuietState() {
        guard kind != .shell, runState == .running else {
            if needsInput { needsInput = false }
            if pendingQuestion != nil { pendingQuestion = nil }
            return
        }
        let term = terminalView.getTerminal()
        let rows = term.rows
        var lines: [String] = []
        lines.reserveCapacity(max(0, rows))
        for r in 0..<rows {
            lines.append(term.getLine(row: r)?.translateToString(trimRight: true) ?? "")
        }
        let (blocked, question) = Self.classifyTail(lines)
        // Set the question BEFORE needsInput, so needsInput's didSet sees the current
        // question when it fires the handoff callback.
        let newQuestion = blocked ? question : nil
        if pendingQuestion != newQuestion { pendingQuestion = newQuestion }
        if !blocked { lastNotifiedQuestion = nil }   // prompt resolved → allow a future notify
        if needsInput != blocked { needsInput = blocked }
    }

    /// Pure heuristic (so it's unit-testable): given the visible terminal lines
    /// (top→bottom), decide whether an agent is asking the user something and what.
    /// Conservative — a missed question still reads as "Waiting", a false positive only
    /// over-reports attention; either way it degrades gracefully.
    static func classifyTail(_ visibleLines: [String]) -> (blocked: Bool, question: String?) {
        let lines = visibleLines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(14)
            .map { String($0) }
        guard let last = lines.last else { return (false, nil) }
        let hay = lines.joined(separator: "\n").lowercased()
        func question() -> String? { lines.last { $0.hasSuffix("?") && $0.count <= 200 } }

        // 1) Explicit yes/no confirmation tokens.
        if ["(y/n)", "[y/n]", "(yes/no)", "[yes/no]", "y/n]", "(y/n/", "[y/n/"].contains(where: hay.contains) {
            return (true, question() ?? last)
        }
        // 2) Interactive selection MENU — a cursor glyph (❯ ▶ ‣ ›) that's a real choice
        // list, NOT the idle composer. A menu has either a numbered option line (optionally
        // cursor-prefixed: "❯ 1. Yes") or 2+ cursor lines. Claude Code's idle ready prompt
        // ("❯Try \"refactor …\"") is a lone glyph with neither, so it stays "waiting".
        let glyphLines = lines.filter { $0.contains("❯") || $0.contains("▶") || $0.contains("‣") || $0.contains("›") }
        let hasNumberedOption = lines.contains {
            $0.range(of: #"^\s*[❯▶‣›]?\s*\d[.)]\s"#, options: .regularExpression) != nil
        }
        if !glyphLines.isEmpty, glyphLines.count >= 2 || hasNumberedOption {
            return (true, question() ?? "Select an option")
        }
        // 3) Permission / confirmation language, checked only in the prompt region (last few
        // lines) so ordinary completion output earlier on screen ("Approved 3 files") can't
        // match. Past-tense-prone words (approve/confirm) are intentionally omitted — the
        // real interrogative cases are caught by the y/n (1) and trailing-? (4) rules.
        let promptRegion = lines.suffix(4).joined(separator: "\n").lowercased()
        let ask = ["do you want", "do you trust", "would you like", "proceed?", "continue?",
                   "allow this", "grant access", "press enter to continue",
                   "select an option", "overwrite?", "are you sure", "[enter] to"]
        if ask.contains(where: promptRegion.contains) {
            return (true, question() ?? last)
        }
        // 4) A trailing question line ending in '?'.
        if last.hasSuffix("?"), last.count <= 200 {
            return (true, last)
        }
        return (false, nil)
    }

    // MARK: Time-in-status

    /// Re-stamp `statusSince` when (and only when) the visible status changes. Called from
    /// the didSet of every input to `displayStatus` (runState / activity / needsInput), so
    /// a fast output burst that doesn't change the status leaves the clock running.
    private func refreshStatusStamp() {
        let now = displayStatus
        guard now != lastStampedStatus else { return }
        lastStampedStatus = now
        statusSince = Date()
    }

    /// Compact "time in status" label, e.g. "12s", "4m", "1h 3m". Nil under 3s (too noisy).
    static func durationLabel(since: Date, now: Date = Date()) -> String? {
        let s = Int(now.timeIntervalSince(since))
        if s < 3 { return nil }
        if s < 60 { return "\(s)s" }
        let m = s / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    /// Single-quote a string for safe use in the shell command we hand to zsh.
    private func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func loginEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment   // inherits HOME, USER, …
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // User-owned extra env, one KEY=VALUE per line (values may contain spaces).
        for line in extraEnv.split(separator: "\n") {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// The canonical five-state status for the card dot / sidebar, derived from the
    /// process state AND live output activity. A running agent that's streaming output
    /// reads "Working"; one that's gone quiet reads "Waiting" (awaiting you); a quiet
    /// plain shell reads "Idle".
    var displayStatus: SessionStatus {
        switch runState {
        case .idle, .recoverable:
            return .idle
        case .preparing:
            return .working                       // async worktree checkout in flight
        case .running:
            if activity == .working { return .working }
            if kind == .shell { return .idle }
            return needsInput ? .blocked : .waiting   // asking you vs idle/ready
        case .exited(let status):
            return status.isClean ? .done : .error
        case .needsCLI:
            return .error
        }
    }

    /// Re-attempt launch (e.g. after the user locates a missing CLI).
    func retryLaunch() {
        guard runState != .preparing else { return }
        cancelPendingPrompt()
        didStart = false
        runState = .idle
        startIfNeeded()
    }

    func restart() {
        // Don't tear down during a worktree checkout — finishPreparing will launch the
        // PTY in the worktree; restarting now would start it in the provisional repo root.
        guard runState != .preparing else { return }
        cancelPendingPrompt()
        resetActivity()
        userInitiatedExit = true
        terminalView.terminate()
        didStart = false
        runState = .idle
        startIfNeeded()
    }

    /// Ctrl+C — interrupt the foreground process group.
    func interrupt() {
        terminalView.send([0x03])
    }

    /// Send text into the live session (Focus Mode re-prompt). `submit` presses
    /// Enter so it goes to the agent as a real follow-up message — never faked.
    func sendInput(_ text: String, submit: Bool) {
        terminalView.send(txt: text)
        if submit { terminalView.send(txt: "\r") }
    }

    func terminate() {
        cancelPendingPrompt()
        resetActivity()
        userInitiatedExit = true
        terminalView.terminate()
    }

    // MARK: Theme — translucent, theme-tinted terminal so the backdrop flows through

    func applyTheme(_ theme: CanvasTheme) {
        terminalView.nativeBackgroundColor = theme.terminalBackground
        terminalView.nativeForegroundColor = theme.terminalForeground
        terminalView.caretColor = theme.terminalCaret
        // Let the translucent background composite over the glass card behind it.
        terminalView.wantsLayer = true
        terminalView.layer?.isOpaque = false
        if let font = NSFont(name: "SFMono-Regular", size: 12.5) ?? NSFont(name: "Menlo", size: 12.5) {
            terminalView.font = font
        }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        resetActivity()
        let status = ExitStatus.decode(exitCode)
        let wasUserInitiated = userInitiatedExit
        userInitiatedExit = false
        runState = .exited(status)
        onExit?(status, wasUserInitiated)
    }
}
