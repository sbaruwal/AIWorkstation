import Foundation

/// Locates the Claude Code / Codex CLIs.
///
/// Detection runs through the user's *login shell* (`$SHELL -lc 'command -v …'`)
/// because the CLIs typically live in PATH entries (`~/.local/bin`, nvm, brew)
/// that a Finder-launched app does not inherit. A manual override (set via the
/// "locate CLI" affordance) always wins. Per the locked decisions we assume the
/// CLIs are already installed and authenticated.
final class AgentCLI {
    static let shared = AgentCLI()

    private let defaults = UserDefaults.standard
    private var detectCache: [AgentKind: String?] = [:]

    private func overrideKey(_ kind: AgentKind) -> String { "agentcli.override.\(kind.rawValue)" }

    /// Binary name as found on PATH.
    func binaryName(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .shell:  return ""
        }
    }

    // MARK: Manual override

    func overridePath(for kind: AgentKind) -> String? {
        guard let p = defaults.string(forKey: overrideKey(kind)), !p.isEmpty else { return nil }
        return p
    }

    func setOverride(_ path: String?, for kind: AgentKind) {
        if let path, !path.isEmpty {
            defaults.set(path, forKey: overrideKey(kind))
        } else {
            defaults.removeObject(forKey: overrideKey(kind))
        }
        detectCache[kind] = nil
    }

    // MARK: Resolution

    /// Override first, else auto-detected absolute path. Nil → not found.
    func resolvedPath(for kind: AgentKind) -> String? {
        if let o = overridePath(for: kind) { return o }
        if let cached = detectCache[kind] { return cached }
        let detected = autodetect(binaryName(kind))
        detectCache[kind] = detected
        return detected
    }

    func isAvailable(_ kind: AgentKind) -> Bool { resolvedPath(for: kind) != nil }

    private func autodetect(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        return detectViaLoginShell(name) ?? detectViaCommonPaths(name)
    }

    /// Ask the user's *interactive* login shell — this sources `.zshrc` (nvm,
    /// brew, `~/.local/bin`), matching how the agent is actually launched and how
    /// the user's own terminal resolves the binary. (A non-interactive `-lc`
    /// shell skips `.zshrc`, which is why detection failed on a normal app launch.)
    ///
    /// An interactive shell can block indefinitely (Powerlevel10k instant-prompt,
    /// `compinit`, `ssh-add`, anything that reads stdin). We guard against that two
    /// ways: stdin is `/dev/null` so a prompt fails fast, and a 4-second watchdog
    /// terminates the shell and gives up rather than freezing the caller forever.
    private func detectViaLoginShell(_ name: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "command -v \(name)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()           // discard shell-startup noise
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Drain + wait on a background queue; bound the whole thing to 4s.
        let sem = DispatchSemaphore(value: 0)
        let box = OutputBox()
        DispatchQueue.global(qos: .userInitiated).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            box.text = String(data: data, encoding: .utf8) ?? ""
            sem.signal()
        }
        if sem.wait(timeout: .now() + 4.0) == .timedOut {
            process.terminate()                  // SIGTERM the stuck shell, give up
            return nil
        }

        // Interactive startup may print banners; take the last line that is an
        // executable absolute path.
        return box.text.split(separator: "\n").map(String.init).last {
            $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    /// Bulletproof fallback: probe the usual install locations directly, so a
    /// quirky shell config can't hide a CLI that is plainly on disk.
    private func detectViaCommonPaths(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.npm-global/bin/\(name)",
            "\(home)/bin/\(name)",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Reference holder so the detection watchdog can hand a value back from its
/// background queue without a struct-capture data race.
private final class OutputBox {
    var text = ""
}
