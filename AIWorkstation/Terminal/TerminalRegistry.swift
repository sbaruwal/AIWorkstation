import Foundation

/// Holds live `TerminalController`s keyed by panel id — in memory only.
///
/// PTYs are never persisted (technical constitution): on relaunch a restored
/// panel simply gets a fresh controller/session. This registry is the boundary
/// between the canvas (which knows panels) and the terminal engine (which knows
/// processes). It also tracks the active canvas theme so new and existing
/// terminals stay tinted to match the backdrop.
@MainActor
final class TerminalRegistry {
    private var controllers: [UUID: TerminalController] = [:]
    private(set) var theme: CanvasTheme = .minimal

    /// Panels restored from disk this launch — their sessions start as recoverable.
    var restoredIds: Set<UUID> = []

    /// Called once when a controller is first created, so CanvasState can wire its
    /// event callbacks (exit / CLI-missing → notifications).
    var onControllerCreated: ((TerminalController) -> Void)?

    func controller(for panel: PanelModel) -> TerminalController {
        if let existing = controllers[panel.id] { return existing }
        let controller = TerminalController(
            id: panel.id, kind: panel.kind, workingDirectory: panel.workingDirectory,
            theme: theme, recoverable: restoredIds.contains(panel.id)
        )
        controllers[panel.id] = controller
        onControllerCreated?(controller)
        return controller
    }

    /// Existing controller without creating one — used by async launch/cleanup to
    /// finalize a session that may have been closed mid-preparation.
    func existingController(for id: UUID) -> TerminalController? {
        controllers[id]
    }

    /// Re-tint all live terminals (and remember the choice for new ones).
    func applyTheme(_ theme: CanvasTheme) {
        self.theme = theme
        for controller in controllers.values {
            controller.applyTheme(theme)
        }
    }

    func remove(_ id: UUID) {
        controllers[id]?.terminate()
        controllers[id] = nil
    }

    /// Retry sessions that couldn't find their CLI binary, after the user locates
    /// or installs it. Detection cache is already cleared by `AgentCLI.setOverride`.
    func retryMissingCLIs() {
        for controller in controllers.values {
            if case .needsCLI = controller.runState { controller.retryLaunch() }
        }
    }
}
