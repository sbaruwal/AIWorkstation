import CoreGraphics

/// Pan/zoom transform between world (canvas) space and screen space.
///
///   screen = world * zoom + pan
///   world  = (screen - pan) / zoom
struct Camera: Equatable {
    var pan: CGSize = .zero
    var zoom: CGFloat = 1.0

    func worldToScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height)
    }

    func screenToWorld(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    /// Screen rect for a world rect (origin = top-left).
    func screenRect(_ r: CGRect) -> CGRect {
        let o = worldToScreen(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * zoom, height: r.height * zoom)
    }

    /// Zoom by a multiplicative factor while keeping `anchor` (a screen point) fixed.
    mutating func zoomBy(_ factor: CGFloat, anchor: CGPoint, minZoom: CGFloat, maxZoom: CGFloat) {
        let newZoom = max(minZoom, min(maxZoom, zoom * factor))
        guard newZoom != zoom else { return }
        let worldUnder = screenToWorld(anchor)
        zoom = newZoom
        pan = CGSize(
            width: anchor.x - worldUnder.x * zoom,
            height: anchor.y - worldUnder.y * zoom
        )
    }
}
