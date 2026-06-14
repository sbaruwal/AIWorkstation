import AppKit

/// Minimal native pickers used by the launch path. The full agent
/// creation flow (command palette, task prompt, review screen) lives elsewhere; here
/// we just need to choose a repo folder and, if needed, locate a CLI binary.
enum RepoPicker {

    @MainActor
    static func pickDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Repo"
        panel.message = "Select a project or repository folder"
        if let defaultRepo = WorkspaceStore.shared.defaultRepoFolder {
            panel.directoryURL = defaultRepo
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func pickExecutable(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This"
        panel.message = message
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
