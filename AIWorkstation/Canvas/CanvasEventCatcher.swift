import SwiftUI
import AppKit

/// Transparent AppKit layer that captures trackpad/mouse events the canvas needs:
/// two-finger scroll → pan, pinch → zoom, empty-space drag → pan, click → deselect.
///
/// It sits *above* the panels but only "claims" points that are not inside a
/// panel's screen frame, so panel drag/resize (handled by SwiftUI) still works.
struct CanvasEventCatcher: NSViewRepresentable {
    /// Panel frames in screen space; points inside these pass through to SwiftUI.
    var panelScreenFrames: [CGRect]

    var onScrollPan: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onDragPan: (CGSize) -> Void
    var onClickEmpty: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.delegateBox = context.coordinator
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        context.coordinator.parent = self
        nsView.panelFrames = panelScreenFrames
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: CanvasEventCatcher
        init(_ parent: CanvasEventCatcher) { self.parent = parent }
    }

    final class CatcherView: NSView {
        weak var delegateBox: Coordinator?
        var panelFrames: [CGRect] = []

        override var isFlipped: Bool { true }          // match SwiftUI top-left origin
        override var acceptsFirstResponder: Bool { true }

        /// Claim empty space, pass panel areas through to the views beneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            for f in panelFrames where f.insetBy(dx: -1, dy: -1).contains(local) {
                return nil
            }
            return bounds.contains(local) ? self : nil
        }

        override func scrollWheel(with event: NSEvent) {
            delegateBox?.parent.onScrollPan(
                CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)
            )
        }

        override func magnify(with event: NSEvent) {
            let loc = convert(event.locationInWindow, from: nil)
            delegateBox?.parent.onMagnify(event.magnification, CGPoint(x: loc.x, y: loc.y))
        }

        private var lastDragLocation: NSPoint?

        override func mouseDown(with event: NSEvent) {
            lastDragLocation = event.locationInWindow
            delegateBox?.parent.onClickEmpty()
        }

        override func mouseDragged(with event: NSEvent) {
            // Track absolute cursor position rather than event.delta* (which can be
            // zero for some event sources) so empty-space drag-to-pan is reliable.
            let loc = event.locationInWindow
            if let last = lastDragLocation {
                // Window coords are bottom-left origin; flip y to screen space.
                delegateBox?.parent.onDragPan(CGSize(width: loc.x - last.x, height: last.y - loc.y))
            }
            lastDragLocation = loc
        }

        override func mouseUp(with event: NSEvent) {
            lastDragLocation = nil
        }
    }
}
