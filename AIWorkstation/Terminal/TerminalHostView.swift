import SwiftUI
import SwiftTerm

/// Mounts a live SwiftTerm terminal inside SwiftUI.
///
/// The terminal view is owned by the controller (kept alive across re-renders);
/// this representable just mounts it and starts the shell on first appearance.
/// Resizing the host frame makes SwiftTerm reflow and emit SIGWINCH to the PTY.
struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var controller: TerminalController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.startIfNeeded()
        let view = controller.terminalView
        // The same PTY view is reused between the canvas card and Focus Mode. AppKit
        // allows only one superview, so detach from any prior host before remounting
        // to avoid a transient double-parent (blink/desync) during the transition.
        view.removeFromSuperview()
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
