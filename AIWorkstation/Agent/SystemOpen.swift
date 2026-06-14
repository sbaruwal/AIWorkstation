import AppKit

/// Open a folder in Finder, a terminal, or an editor (Agent Workflow session
/// controls). Editor tries common apps in order and falls back to Finder.
enum SystemOpen {

    @MainActor static func finder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor static func terminal(_ path: String) {
        open(app: "Terminal", path: path)
    }

    @MainActor static func editor(_ path: String) {
        for app in ["Visual Studio Code", "Cursor", "Visual Studio Code - Insiders", "Zed", "Sublime Text"] {
            if open(app: app, path: path) { return }
        }
        finder(path)
    }

    /// `open -a <app> <path>` — returns true if it launched successfully.
    @discardableResult
    @MainActor private static func open(app: String, path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", app, path]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
