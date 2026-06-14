import Foundation

/// Local-first JSON persistence (no SQLite in V1, per locked decision).
///
/// Files live under `~/Library/Application Support/AIWorkstation/`. The store
/// never persists a live PTY as if running — Phase 1 only persists layout +
/// metadata, which is exactly what survives a relaunch.
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private let fm = FileManager.default

    /// `~/Library/Application Support/AIWorkstation`
    let appSupportDir: URL

    /// External, app-managed worktree root (created later in Phase 4, but the
    /// path is reserved here so the location is centralized and never inside a repo).
    let worktreesDir: URL

    private var workspaceFile: URL { appSupportDir.appendingPathComponent("workspace.json") }

    /// Last folder a repo was picked from (used to seed the next picker).
    /// The full default-repo-folder setting arrives with the Phase 7 Settings UI.
    var defaultRepoFolder: URL? {
        get { defaults.url(forKey: "defaultRepoFolder") }
        set { defaults.set(newValue, forKey: "defaultRepoFolder") }
    }

    /// Recently launched repos, most-recent first (for the New Agent flow + palette).
    var recentRepos: [URL] {
        (defaults.array(forKey: "recentRepos") as? [String])?
            .map { URL(fileURLWithPath: $0) } ?? []
    }

    func pushRecentRepo(_ url: URL) {
        var paths = (defaults.array(forKey: "recentRepos") as? [String]) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        defaults.set(Array(paths.prefix(8)), forKey: "recentRepos")
    }

    private let defaults = UserDefaults.standard

    /// Serial queue for disk writes so autosave never blocks the main thread and
    /// concurrent saves can't interleave / corrupt the file.
    private let ioQueue = DispatchQueue(label: "com.aiworkstation.workspace-io", qos: .utility)

    private init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = base.appendingPathComponent("AIWorkstation", isDirectory: true)
        worktreesDir = appSupportDir.appendingPathComponent("Worktrees", isDirectory: true)
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    /// Load all canvases. Prefers the multi-canvas container format; falls back to the
    /// previous single-`Workspace` format (wrapping it) so old saves migrate cleanly.
    func loadAll() -> WorkspaceFile? {
        guard let data = try? Data(contentsOf: workspaceFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // New container format (has a `workspaces` array).
        if let file = try? decoder.decode(WorkspaceFile.self, from: data), !file.workspaces.isEmpty {
            return file
        }
        // Old single-Workspace format → wrap it.
        if let ws = try? decoder.decode(Workspace.self, from: data) {
            return WorkspaceFile(workspaces: [ws], currentWorkspaceID: ws.id)
        }
        // Neither decoded: preserve the unreadable file and don't wipe it.
        NSLog("[AIWorkstation] workspace.json failed to decode")
        let backup = workspaceFile.appendingPathExtension("corrupt")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: workspaceFile, to: backup)
        return nil
    }

    /// Asynchronous save (autosave path) — encode on the caller, write off-main.
    func saveAll(_ file: WorkspaceFile) {
        guard let data = encode(file) else { return }
        let url = workspaceFile
        ioQueue.async { try? data.write(to: url, options: .atomic) }
    }

    /// Synchronous save (quit path) — ordered after pending writes, completes before exit.
    func saveAllSynchronously(_ file: WorkspaceFile) {
        guard let data = encode(file) else { return }
        let url = workspaceFile
        ioQueue.sync { try? data.write(to: url, options: .atomic) }
    }

    private func encode(_ file: WorkspaceFile) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(file)
    }
}
