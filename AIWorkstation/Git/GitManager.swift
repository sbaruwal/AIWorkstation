import Foundation

/// A file reported by `git status --porcelain`.
struct ChangedFile: Identifiable, Equatable {
    var id: String { path }
    let status: String   // 2-char XY code, e.g. " M", "??", "A "
    let path: String

    var isUntracked: Bool { status == "??" }
}

enum GitError: LocalizedError {
    case command(String)
    var errorDescription: String? {
        switch self { case .command(let m): return m }
    }
}

/// Thin wrapper over the `git` CLI for the repo/worktree operations needed here:
/// detect repo, create/remove worktrees + branches, list changed files.
///
/// Same-repo isolation uses real git worktrees stored in an **external**
/// app-managed folder (never inside the repo):
/// `~/Library/Application Support/AIWorkstation/Worktrees/{workspaceId}/{agentId}`.
/// Branches follow `agent/{kind}-{timestamp}`. Merge stays manual/review-first.
///
/// This type holds no mutable state (`gitPath`/`worktreesRoot` are `let`), so it
/// is intentionally **not** `@MainActor`: every method is safe to call from a
/// background queue, and the blocking `run()` should be — callers that touch the
/// UI hop off the main thread (see `changedFiles`/`fileDiff` usage in the views).
final class GitManager {
    static let shared = GitManager()

    private let gitPath = "/usr/bin/git"
    let worktreesRoot: URL

    init() {
        worktreesRoot = WorkspaceStore.shared.worktreesDir
    }

    // MARK: Repo detection

    func isGitRepo(_ path: String) -> Bool {
        let r = run(["-C", path, "rev-parse", "--is-inside-work-tree"])
        return r.status == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Absolute top-level of the *main* working tree for `path`, or nil if not a repo.
    func repoRoot(_ path: String) -> String? {
        let r = run(["-C", path, "rev-parse", "--show-toplevel"])
        guard r.status == 0 else { return nil }
        let root = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return root.isEmpty ? nil : root
    }

    // MARK: Worktrees

    func makeBranchName(kind: AgentKind, taskSlug: String?) -> String {
        let ts = Self.timestamp.string(from: Date())
        let base: String
        if let slug = taskSlug?.slugified, !slug.isEmpty {
            base = "agent/\(kind.rawValue)-\(slug)-\(ts)"
        } else {
            base = "agent/\(kind.rawValue)-\(ts)"
        }
        return Self.sanitizeRef(base)
    }

    /// Git refnames forbid spaces and `~^:?*[\` (among others). Keep a safe set
    /// and map anything else to `-`, so a quirky locale can never produce an
    /// invalid branch name.
    static func sanitizeRef(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-_.")
        return String(s.map { allowed.contains($0) ? $0 : "-" })
    }

    func worktreePath(workspaceId: UUID, agentId: UUID) -> String {
        worktreesRoot
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent(agentId.uuidString, isDirectory: true)
            .path
    }

    /// `git worktree add -b <branch> <path>` — new branch off HEAD in a fresh dir.
    func createWorktree(repoRoot: String, branch: String, at path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let r = run(["-C", repoRoot, "worktree", "add", "-b", branch, path])
        if r.status != 0 {
            let msg = r.err.isEmpty ? "git worktree add failed (status \(r.status))" : r.err
            throw GitError.command(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func removeWorktree(repoRoot: String, at path: String, force: Bool) throws {
        var args = ["-C", repoRoot, "worktree", "remove", path]
        if force { args.append("--force") }
        let r = run(args)
        // Prune any dangling administrative entries regardless of outcome.
        _ = run(["-C", repoRoot, "worktree", "prune"])
        guard r.status != 0 else { return }

        // Removal failed (dir busy, partially deleted, etc.). Rather than leave an
        // orphaned worktree behind, force the admin entry away and delete the dir
        // ourselves, then re-prune. Only surface an error if the dir truly remains.
        _ = run(["-C", repoRoot, "worktree", "remove", "--force", path])
        try? FileManager.default.removeItem(atPath: path)
        _ = run(["-C", repoRoot, "worktree", "prune"])
        if FileManager.default.fileExists(atPath: path) {
            let msg = r.err.isEmpty ? "git worktree remove failed (status \(r.status))" : r.err
            throw GitError.command(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Ship It (review → merge)

    /// True when the working dir has no uncommitted changes (tracked or untracked).
    func isClean(_ path: String) -> Bool {
        let r = run(["-C", path, "status", "--porcelain"])
        return r.status == 0 && r.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Stage everything and commit in the worktree. Returns false (NOT an error) when
    /// there was nothing to commit. Throws on a real git failure.
    @discardableResult
    func commitAll(at worktree: String, message: String) throws -> Bool {
        _ = run(["-C", worktree, "add", "-A"])
        if isClean(worktree) { return false }   // nothing to commit
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = run(["-C", worktree, "commit", "-m", msg.isEmpty ? "Agent changes" : msg])
        if r.status != 0 {
            throw GitError.command((r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return true
    }

    /// Merge `branch` into the branch currently checked out in `repoRoot`. The main repo
    /// must be clean first (we never merge over uncommitted work); a conflicting merge is
    /// ABORTED and surfaced rather than left half-applied — the user resolves manually.
    func mergeBranch(_ branch: String, into repoRoot: String) throws {
        guard isClean(repoRoot) else {
            throw GitError.command("The main repo has uncommitted changes — commit or stash them first, then ship.")
        }
        let r = run(["-C", repoRoot, "merge", "--no-edit", branch])
        if r.status != 0 {
            _ = run(["-C", repoRoot, "merge", "--abort"])   // restore the repo to its pre-merge state
            let detail = (r.out + "\n" + r.err).trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError.command("Merging \(branch) hit conflicts and was aborted — resolve it manually.\n\(detail)")
        }
    }

    /// The branch currently checked out in a repo (for showing the merge target).
    func currentBranch(at repoRoot: String) -> String? {
        let r = run(["-C", repoRoot, "rev-parse", "--abbrev-ref", "HEAD"])
        guard r.status == 0 else { return nil }
        let b = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty || b == "HEAD" ? nil : b
    }

    /// Count of commits on `branch` not reachable from the main checkout's HEAD —
    /// i.e. *committed* work that would be lost if the worktree+branch are discarded.
    /// Complements `changedFiles` (which only sees uncommitted edits).
    func unmergedCommitCount(repoRoot: String, branch: String) -> Int {
        let r = run(["-C", repoRoot, "rev-list", "--count", "HEAD..\(branch)"])
        guard r.status == 0 else { return 0 }
        return Int(r.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// A snapshot of a working dir's git state for the Focus Mode header.
    struct RepoState: Equatable {
        var branch: String          // current branch (or short SHA when detached)
        var changedCount: Int       // dirty files (tracked + untracked)
        var ahead: Int              // commits ahead of the comparison base
        var behind: Int             // commits behind it
        var hasUpstream: Bool       // whether ahead/behind are meaningful
    }

    /// Branch + dirty count + ahead/behind for `path`. Ahead/behind compares to the
    /// upstream if one is set, else to `compareBase` (the branch a worktree forked
    /// from), so worktree agents still show progress. **Blocking** — call off-main.
    func repoState(at path: String, compareBase: String? = nil) -> RepoState? {
        guard isGitRepo(path) else { return nil }
        let head = run(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
        guard head.status == 0 else { return nil }
        var branch = head.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch == "HEAD" {   // detached → short SHA
            let sha = run(["-C", path, "rev-parse", "--short", "HEAD"])
            branch = sha.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let changed = changedFiles(at: path).count

        // Prefer the configured upstream; otherwise fall back to the fork base.
        let upstream = run(["-C", path, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        let base: String?
        let hasUpstream: Bool
        if upstream.status == 0 {
            base = upstream.out.trimmingCharacters(in: .whitespacesAndNewlines); hasUpstream = true
        } else if let compareBase {
            base = compareBase; hasUpstream = false
        } else {
            base = nil; hasUpstream = false
        }

        var ahead = 0, behind = 0
        if let base, !base.isEmpty {
            // left-right count of base...HEAD → "behind<TAB>ahead".
            let counts = run(["-C", path, "rev-list", "--left-right", "--count", "\(base)...HEAD"])
            if counts.status == 0 {
                let parts = counts.out.split(whereSeparator: { $0 == "\t" || $0 == " " })
                if parts.count == 2 { behind = Int(parts[0]) ?? 0; ahead = Int(parts[1]) ?? 0 }
            }
        }
        return RepoState(branch: branch, changedCount: changed, ahead: ahead, behind: behind,
                         hasUpstream: hasUpstream || (base != nil))
    }

    // MARK: Status

    /// Unified diff for one file. Untracked files are diffed against /dev/null so
    /// binary and large files render correctly (instead of an empty UTF-8 read).
    func fileDiff(at path: String, file: ChangedFile) -> String {
        if file.isUntracked {
            let full = (path as NSString).appendingPathComponent(file.path)
            // --no-index handles binary ("Binary files … differ") and text uniformly.
            // It exits 1 when the files differ — expected here, not an error.
            let r = run(["-C", path, "diff", "--no-index", "--", "/dev/null", full])
            if !r.out.isEmpty { return r.out }
            // Fallback for the rare empty-output case (e.g. brand-new empty file).
            let content = (try? String(contentsOfFile: full, encoding: .utf8)) ?? ""
            return content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "+" + $0 }
                .joined(separator: "\n")
        }
        let r = run(["-C", path, "diff", "--", file.path])
        return r.out
    }

    func changedFiles(at path: String) -> [ChangedFile] {
        // `-z` keeps paths verbatim (no octal-quoting of non-ASCII / spaces) and
        // NUL-terminates records. Renames/copies append a second NUL field holding
        // the *original* path, which we consume so it isn't parsed as its own entry.
        let r = run(["-C", path, "status", "--porcelain", "-z"])
        guard r.status == 0 else { return [] }

        let tokens = r.out.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var files: [ChangedFile] = []
        var i = 0
        while i < tokens.count {
            let entry = tokens[i]
            i += 1
            guard entry.count >= 4 else { continue }   // skips the trailing empty token
            let code = String(entry.prefix(2))
            let newPath = String(entry.dropFirst(3))   // "XY <path>" → <path> (the post-rename name)
            let x = code.first, y = code.dropFirst().first
            if x == "R" || x == "C" || y == "R" || y == "C" {
                if i < tokens.count { i += 1 }          // consume the original-path field
            }
            files.append(ChangedFile(status: code, path: newPath))
        }
        return files
    }

    // MARK: Process

    /// Runs `git` to completion and returns (status, stdout, stderr). **Blocking** —
    /// call off the main thread for anything UI-facing.
    ///
    /// stdout and stderr are drained on background queues *concurrently* with the
    /// process running, so a child that writes more than a pipe buffer (~64 KB) to
    /// one stream while we read the other can't deadlock. stdin is /dev/null so a
    /// git that unexpectedly prompts fails fast instead of hanging forever.
    private func run(_ args: [String]) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitPath)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return (-1, "", "\(error.localizedDescription)")
        }

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let q = DispatchQueue.global(qos: .userInitiated)
        group.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.wait()
        process.waitUntilExit()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }

    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        // Fixed POSIX locale → stable 24-hour digits with no AM/PM or spaces.
        // (The device locale, e.g. en_NP, otherwise yields "0613-60100 PM".)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMdd-HHmmss"
        return f
    }()
}

private extension String {
    /// Lowercase, hyphenated, alphanumeric-only slug (max ~24 chars) for branch names.
    var slugified: String {
        let lowered = lowercased()
        let mapped = lowered.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(24))
    }
}
