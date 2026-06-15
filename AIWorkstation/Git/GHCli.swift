import Foundation

/// Thin wrapper around the GitHub CLI (`gh`) for opening a PR from a worktree branch.
/// `gh` is an OPTIONAL dependency beyond the agent CLIs — detected like claude/codex via
/// the login shell, and the Open-PR affordance simply doesn't appear when it's absent or
/// the repo has no remote. Uses the user's already-authed `gh`; adds no accounts/backend.
enum GHCli {
    private static var present = false

    /// Whether `gh` is on the login-shell PATH. Memoizes only a POSITIVE result, so a `gh`
    /// installed after launch is picked up on the next check (the shell-out runs off-main).
    static func isAvailable() -> Bool {
        if present { return true }
        present = shell("command -v gh").status == 0
        return present
    }

    /// Push the branch (set upstream) and open a PR filled from its commits. Returns the
    /// PR URL on success. BLOCKING — call from a detached task.
    static func openPR(worktree: String, branch: String) -> Result<String, GitError> {
        let push = shell("cd \(q(worktree)) && git push -u origin \(q(branch))")
        if push.status != 0 {
            return .failure(.command(trimmed(push.err.isEmpty ? push.out : push.err)))
        }
        let pr = shell("cd \(q(worktree)) && gh pr create --fill --head \(q(branch))")
        if pr.status != 0 {
            return .failure(.command(trimmed(pr.err.isEmpty ? pr.out : pr.err)))
        }
        // gh prints the PR URL on stdout; pick the last http(s) token.
        let combined = pr.out + "\n" + pr.err
        let url = combined.split(separator: "\n").last { $0.contains("http") }.map(String.init) ?? pr.out
        return .success(trimmed(url))
    }

    // MARK: - Shell

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func shell(_ command: String) -> (status: Int32, out: String, err: String) {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shellPath)
        p.arguments = ["-lc", command]
        p.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: outData, encoding: .utf8) ?? "", String(data: errData, encoding: .utf8) ?? "")
    }
}
