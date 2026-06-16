import SwiftUI

/// Optional deep-work view for one agent. A large live terminal
/// beside a changed-files list + native unified-diff viewer, with quick controls
/// and a re-prompt bar. Never required for normal interaction; Esc returns to the
/// exact canvas. The same PTY view is reused — the canvas card releases it while
/// focused so there's no double-mount.
struct FocusModeView: View {
    @ObservedObject var state: CanvasState
    @ObservedObject var terminal: TerminalController
    let panel: PanelModel
    let theme: CanvasTheme

    @State private var sideWidth: CGFloat = 400
    @State private var dragStartWidth: CGFloat?
    @State private var files: [ChangedFile] = []
    @State private var selectedFile: ChangedFile?
    @State private var diff: String = ""
    @State private var diffLines: [DiffLineRow] = []   // pre-parsed + pre-styled, rendered lazily
    @State private var reprompt: String = ""
    @State private var repoState: GitManager.RepoState?
    @State private var hasConstitution = false
    @State private var hasMemory = false
    // Ship It
    @State private var commitMessage = ""
    @State private var confirmingShip = false
    @State private var confirmingReject = false
    @State private var testCommand = ""
    @State private var testing = false
    @State private var testResult: TestRunner.Result?
    @State private var showTestOutput = false
    @State private var usage: UsageLedger.Usage?
    @State private var canOpenPR = false
    @State private var mergeTargetBranch = ""   // the repo root's current branch (the real merge destination)

    private var workingDir: String { panel.workingDirectory ?? panel.repoRoot ?? "" }
    private var isGit: Bool { panel.repoRoot != nil }
    /// Ship It only applies to an isolated-worktree agent (there's a branch to merge back).
    private var canShip: Bool { panel.isWorktree && panel.repoRoot != nil && panel.branch != nil }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 0) {
                terminalPane
                if isGit {
                    paneDivider
                    sidePane.frame(width: sideWidth)
                }
            }
            repromptBar
        }
        .background(backdrop)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
        .onAppear { reloadChanges(); reloadRepoState(); reloadUsage(); reloadPRAvailability(); reloadMergeTarget(); testCommand = TestRunner.command(for: workingDir) }
        .confirmationDialog("Ship this agent's work?", isPresented: $confirmingShip, titleVisibility: .visible) {
            Button("Commit & Merge") { state.shipPanel(panel.id, message: effectiveCommitMessage); state.exitFocus() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Commit the changes, merge \(branchShort) into \(mergeTargetBranch.isEmpty ? "the base branch" : mergeTargetBranch), then close this agent.")
        }
        .confirmationDialog("Discard this agent's work?", isPresented: $confirmingReject, titleVisibility: .visible) {
            Button("Discard & Close", role: .destructive) { state.exitFocus(); state.removePanel(panel.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Closes the agent and removes its worktree. Uncommitted changes are confirmed separately.")
        }
    }

    private var branchShort: String {
        (panel.branch ?? "").replacingOccurrences(of: "agent/", with: "")
    }
    private var effectiveCommitMessage: String {
        let t = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? (panel.task.isEmpty ? "Agent changes" : panel.task) : t
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Circle().fill(panel.kind.tint).frame(width: 8, height: 8)
            Image(systemName: panel.kind.glyph).font(.system(size: 12, weight: .semibold)).foregroundStyle(panel.kind.tint)
            Text(panel.headerTitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)

            if let u = usage { usageLabel(u) }

            Spacer()

            // Agent switcher — jump focus to another agent. Browser nodes are excluded
            // (Focus Mode is terminal-only; focusing a browser would spawn a stray PTY).
            let others = state.panels.filter { $0.id != panel.id && !$0.isBrowser }
            if !others.isEmpty {
                Menu {
                    ForEach(others) { other in
                        Button(other.headerTitle) { state.enterFocus(other.id) }
                    }
                } label: {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("Switch agent")
            }

            control("stop.fill", "Interrupt") { terminal.interrupt() }
            control("arrow.clockwise", "Restart") { terminal.restart() }
            if state.canClone(panel.id) {
                control("plus.square.on.square", "Clone") { state.clonePanel(panel.id) }
            }
            control("arrow.down.right.and.arrow.up.left", "Exit Focus (Esc)") { state.exitFocus() }
        }
        .padding(.horizontal, 16).frame(height: 46)
    }

    /// Compact local token-usage readout (Claude agents) — tokens always, plus a $ value
    /// only when the user has set a $/Mtok rate (clearly an estimate, never a fetched price).
    private func usageLabel(_ u: UsageLedger.Usage) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 9, weight: .semibold))
            Text("\(UsageLedger.formatTokens(u.totalTokens)) tok")
            if let cost = UsageLedger.estimatedCost(u) {
                Text(String(format: "· ~$%.2f", cost))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(Theme.textTertiary)
        .help("Approximate local token usage for this agent's working directory" +
              (UsageLedger.estimatedCost(u) != nil ? " · cost is your configured $/Mtok estimate" : " · set a $/Mtok rate in Settings for a cost estimate"))
    }

    private func reloadUsage() {
        let kind = panel.kind, dir = workingDir
        Task { @MainActor in usage = await Task.detached { UsageLedger.usage(for: kind, cwd: dir) }.value }
    }

    private func control(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }.buttonStyle(.plain).help(help)
    }

    // MARK: Terminal

    private var terminalPane: some View {
        TerminalHostView(controller: terminal)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.02, green: 0.03, blue: 0.05))
    }

    private var paneDivider: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
            .overlay(Color.clear.frame(width: 10).contentShape(Rectangle())
                .gesture(DragGesture()
                    // Resolve width from the width captured at drag-start + the
                    // gesture's *cumulative* translation. Subtracting from the live
                    // `sideWidth` each frame would compound and jitter.
                    .onChanged { v in
                        let start = dragStartWidth ?? sideWidth
                        if dragStartWidth == nil { dragStartWidth = start }
                        sideWidth = min(620, max(280, start - v.translation.width))
                    }
                    .onEnded { _ in dragStartWidth = nil }))
    }

    // MARK: Side pane — changed files + diff

    private var sidePane: some View {
        VStack(spacing: 0) {
            repoStateStrip
            Divider().overlay(Color.white.opacity(0.08))
            contextSection
            Divider().overlay(Color.white.opacity(0.08))

            HStack {
                Text("CHANGED FILES").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(files.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.textTertiary)
                Button { reloadChanges(); reloadRepoState() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary) }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            changedFilesList.frame(height: 150)
            Divider().overlay(Color.white.opacity(0.08))
            diffView
            if canShip {
                Divider().overlay(Color.white.opacity(0.08))
                shipSection
            }
        }
        .background(Color.black.opacity(0.25))
    }

    // MARK: Ship It (review → merge)

    private var shipSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHIP IT").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
                Spacer()
                testControl
            }
            TextField(panel.task.isEmpty ? "Commit message" : panel.task, text: $commitMessage)
                .textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            HStack(spacing: 6) {
                shipButton("Commit", "tray.and.arrow.down", tint: Theme.textSecondary) {
                    state.commitWorktree(panel.id, message: effectiveCommitMessage)
                }
                shipButton("Accept", "checkmark", tint: SessionStatus.done.tint, filled: true) { confirmingShip = true }
                shipButton("Reject", "xmark", tint: SessionStatus.error.tint) { confirmingReject = true }
                if canOpenPR {
                    shipButton("PR", "arrow.triangle.pull", tint: state.accent) {
                        state.openPullRequest(panel.id, message: effectiveCommitMessage)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// `gh` is optional — only show the PR button when it's installed AND the repo has a
    /// remote. Checked off-main (both shell out) so the cockpit never blocks.
    private func reloadPRAvailability() {
        guard let repoRoot = panel.repoRoot else { return }
        Task { @MainActor in
            canOpenPR = await Task.detached { GHCli.isAvailable() && GitManager.shared.hasRemote(repoRoot) }.value
        }
    }

    /// The real merge destination is the REPO ROOT's current branch (not the worktree's
    /// own branch, which `repoState` reads). Resolved off-main for the ship confirmation.
    private func reloadMergeTarget() {
        guard let root = panel.repoRoot else { return }
        Task { @MainActor in
            mergeTargetBranch = await Task.detached { GitManager.shared.currentBranch(at: root) ?? "" }.value
        }
    }

    private func shipButton(_ label: String, _ icon: String, tint: Color, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(filled ? .white : tint)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(filled ? AnyShapeStyle(tint.opacity(0.9)) : AnyShapeStyle(tint.opacity(0.14)),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// User-pressed test run — exit-code only, never auto-judged. Tap the verdict to
    /// peek at the tail output. If no command is detected, the field lets you set one.
    @ViewBuilder private var testControl: some View {
        HStack(spacing: 6) {
            if let r = testResult {
                Button { showTestOutput.toggle() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        Text(r.passed ? "passed" : "exit \(r.exitCode)")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(r.passed ? SessionStatus.done.tint : SessionStatus.error.tint)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showTestOutput, arrowEdge: .bottom) { testOutputPopover(r) }
            }
            Button(action: runTests) {
                HStack(spacing: 3) {
                    if testing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "play.circle").font(.system(size: 11, weight: .semibold)) }
                    Text("Tests").font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(testing)
        }
    }

    private func testOutputPopover(_ r: TestRunner.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(r.passed ? "Tests passed" : "Tests failed · exit \(r.exitCode)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(r.passed ? SessionStatus.done.tint : SessionStatus.error.tint)
                Spacer()
                Text(testCommand).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            }
            ScrollView {
                Text(r.output.isEmpty ? "(no output)" : r.output)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(width: 460, height: 280)
        }
        .padding(12)
    }

    private func runTests() {
        let dir = workingDir
        let cmd = TestRunner.command(for: dir)
        guard !cmd.isEmpty else {
            // Nothing detected/configured → let the user set a command via the message field.
            state.notifier.post("No test command", body: "Set one in Settings or this repo has no recognized test setup.", kind: .info, system: false)
            return
        }
        testCommand = cmd
        testing = true
        testResult = nil
        Task { @MainActor in
            let r = await Task.detached { TestRunner.run(cmd, in: dir) }.value
            testResult = r
            testing = false
        }
    }

    // MARK: Repo-state summary (branch · ahead/behind · dirty)

    private var repoStateStrip: some View {
        HStack(spacing: 10) {
            if let s = repoState {
                Label(s.branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                if s.hasUpstream && (s.ahead > 0 || s.behind > 0) {
                    HStack(spacing: 6) {
                        if s.ahead > 0 { countPill("arrow.up", s.ahead, SessionStatus.done.tint) }
                        if s.behind > 0 { countPill("arrow.down", s.behind, SessionStatus.waiting.tint) }
                    }
                }
                Spacer(minLength: 4)
                Text(s.changedCount == 0 ? "clean" : "\(s.changedCount) changed")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(s.changedCount == 0 ? SessionStatus.done.tint : SessionStatus.waiting.tint)
            } else {
                Text(isGit ? "Reading repo…" : "Not a git repo")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Spacer()
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
    }

    private func countPill(_ icon: String, _ n: Int, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text("\(n)").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: Context (constitution / memory / task)

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CONTEXT").font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 6) {
                contextPill("constitution.md", present: hasConstitution)
                contextPill("memory.md", present: hasMemory)
            }
            if !panel.task.isEmpty {
                Text(panel.task)
                    .font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextPill(_ name: String, present: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: present ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(present ? SessionStatus.done.tint : Theme.textTertiary)
            Text(name).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(present ? Theme.textSecondary : Theme.textTertiary)
        }
        .padding(.horizontal, 6).padding(.vertical, 2.5)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var changedFilesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if files.isEmpty {
                    Text("No changes").font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(10)
                }
                ForEach(files) { file in
                    Button { select(file) } label: {
                        HStack(spacing: 8) {
                            Text(file.status.replacingOccurrences(of: " ", with: "·"))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint(file)).frame(width: 20, alignment: .leading)
                            Text(file.path).font(.system(size: 11)).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(selectedFile == file ? Color.white.opacity(0.06) : .clear)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    /// One pre-parsed, pre-styled diff line — colours are computed once when the diff
    /// loads (not per render) so a large diff doesn't re-classify every line each frame.
    struct DiffLineRow: Identifiable {
        let id: Int
        let text: String
        let color: Color
        let bg: Color
    }

    /// Cap rows kept in memory so a pathological diff (a minified bundle, a lockfile)
    /// can't build a multi-hundred-thousand-element array. LazyVStack handles the rest.
    private static let maxDiffLines = 4000

    private func rebuildDiffLines() {
        guard !diff.isEmpty else { diffLines = []; return }
        let raw = diff.split(separator: "\n", omittingEmptySubsequences: false)
        var rows: [DiffLineRow] = []
        rows.reserveCapacity(min(raw.count, Self.maxDiffLines) + 1)
        for (i, sub) in raw.prefix(Self.maxDiffLines).enumerated() {
            let line = String(sub)
            rows.append(DiffLineRow(id: i, text: line.isEmpty ? " " : line, color: diffColor(line), bg: diffBg(line)))
        }
        if raw.count > Self.maxDiffLines {
            rows.append(DiffLineRow(id: Self.maxDiffLines,
                                    text: "… \(raw.count - Self.maxDiffLines) more lines — open the file to see the rest",
                                    color: Theme.textTertiary, bg: .clear))
        }
        diffLines = rows
    }

    private var diffView: some View {
        ScrollView([.vertical, .horizontal]) {
            if diffLines.isEmpty {
                Text(selectedFile == nil ? "Select a file to see its diff" : "No diff")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(12)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diffLines) { row in
                        Text(row.text)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(row.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .background(row.bg)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: diff) { _, _ in rebuildDiffLines() }
    }

    // MARK: Re-prompt bar

    private var repromptBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            TextField("Follow up this agent — or a command (open …, tell …)", text: $reprompt)
                .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(Theme.textPrimary)
                .onSubmit(sendReprompt)
            Button(action: sendReprompt) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 19)).foregroundStyle(state.accent)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.black.opacity(0.3))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1) }
    }

    // MARK: Actions

    private func reloadChanges() {
        guard isGit else { return }
        let dir = workingDir
        let priorPath = selectedFile?.path     // preserve selection by path, not value
        Task { @MainActor in
            let result = await Task.detached { GitManager.shared.changedFiles(at: dir) }.value
            files = result
            if let p = priorPath, let updated = result.first(where: { $0.path == p }) {
                select(updated)
            } else {
                selectedFile = nil
                diff = ""
            }
        }
    }

    private func reloadRepoState() {
        guard isGit else { repoState = nil; return }
        let dir = workingDir
        // constitution.md / memory.md are repo-root, committed files (so worktrees
        // see them) — probe the repo root, matching buildLaunchPrompt.
        let probeDir = panel.repoRoot ?? dir
        Task { @MainActor in
            let s = await Task.detached { GitManager.shared.repoState(at: dir) }.value
            repoState = s
            let fm = FileManager.default
            hasConstitution = fm.fileExists(atPath: (probeDir as NSString).appendingPathComponent("constitution.md"))
            hasMemory = fm.fileExists(atPath: (probeDir as NSString).appendingPathComponent("memory.md"))
        }
    }

    private func select(_ file: ChangedFile) {
        selectedFile = file
        let dir = workingDir
        Task { @MainActor in
            diff = await Task.detached { GitManager.shared.fileDiff(at: dir, file: file) }.value
        }
    }

    private func sendReprompt() {
        let text = reprompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Routes via the focus composer: plain prose → follow-up to THIS agent;
        // a recognized command → browser/control/spawn like the main bar.
        state.sendFromFocus(text, focusedId: panel.id, viewportSize: state.lastViewport)
        reprompt = ""
    }

    private func tint(_ file: ChangedFile) -> Color {
        if file.isUntracked { return SessionStatus.waiting.tint }
        switch file.status.first ?? " " {
        case "A": return SessionStatus.done.tint
        case "D": return SessionStatus.error.tint
        default:  return state.accent
        }
    }

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.45, green: 0.85, blue: 0.55) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 0.95, green: 0.5, blue: 0.5) }
        if line.hasPrefix("@@") { return state.accent }
        if line.hasPrefix("diff ") || line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("index ") { return Theme.textTertiary }
        return Theme.textSecondary
    }

    private func diffBg(_ line: String) -> Color {
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Color(red: 0.2, green: 0.6, blue: 0.3).opacity(0.10) }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Color(red: 0.7, green: 0.25, blue: 0.25).opacity(0.10) }
        return .clear
    }

    private var backdrop: some View {
        ZStack { VisualEffectView(material: .underWindowBackground, blending: .behindWindow); Color.black.opacity(0.55) }
    }
}
