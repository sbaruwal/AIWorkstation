import SwiftUI

/// Bottom-right minimap: shows all panels and the current viewport rectangle.
/// Click anywhere to recenter the camera on that point.
struct MinimapView: View {
    let panels: [PanelModel]
    let camera: Camera
    let viewportSize: CGSize
    var onNavigate: ((CGPoint) -> Void)? = nil

    private let mapSize = CGSize(width: 172, height: 116)
    private let padding: CGFloat = 8

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.chromeFill)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.chromeStroke, lineWidth: 1))

            if let transform = transform() {
                ForEach(panels) { panel in
                    let r = transform(panel.worldFrame)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(panel.kind.tint.opacity(0.55))
                        .frame(width: max(3, r.width), height: max(3, r.height))
                        .offset(x: r.minX, y: r.minY)
                }

                // Viewport rectangle (in world space → minimap space).
                let viewWorld = currentViewportWorldRect()
                let vr = transform(viewWorld)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.9), lineWidth: 1.2)
                    .frame(width: max(6, vr.width), height: max(6, vr.height))
                    .offset(x: vr.minX, y: vr.minY)
            }
        }
        .frame(width: mapSize.width, height: mapSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 14, y: 6)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onEnded { value in
                    if let world = worldPoint(fromMinimap: value.location) {
                        onNavigate?(world)
                    }
                }
        )
    }

    /// Inverse of `transform()`: a point in minimap space → world coordinates.
    private func worldPoint(fromMinimap p: CGPoint) -> CGPoint? {
        var bounds = currentViewportWorldRect()
        for panel in panels { bounds = bounds.union(panel.worldFrame) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let availW = mapSize.width - padding * 2
        let availH = mapSize.height - padding * 2
        let scale = min(availW / bounds.width, availH / bounds.height)
        guard scale > 0 else { return nil }
        let offsetX = padding + (availW - bounds.width * scale) / 2
        let offsetY = padding + (availH - bounds.height * scale) / 2
        return CGPoint(
            x: bounds.minX + (p.x - offsetX) / scale,
            y: bounds.minY + (p.y - offsetY) / scale
        )
    }

    private func currentViewportWorldRect() -> CGRect {
        let origin = camera.screenToWorld(.zero)
        let far = camera.screenToWorld(CGPoint(x: viewportSize.width, y: viewportSize.height))
        return CGRect(x: origin.x, y: origin.y, width: far.x - origin.x, height: far.y - origin.y)
    }

    /// Build a world→minimap transform that fits panels + viewport with padding.
    private func transform() -> ((CGRect) -> CGRect)? {
        var bounds = currentViewportWorldRect()
        for p in panels { bounds = bounds.union(p.worldFrame) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let availW = mapSize.width - padding * 2
        let availH = mapSize.height - padding * 2
        let scale = min(availW / bounds.width, availH / bounds.height)
        let offsetX = padding + (availW - bounds.width * scale) / 2
        let offsetY = padding + (availH - bounds.height * scale) / 2

        return { rect in
            CGRect(
                x: offsetX + (rect.minX - bounds.minX) * scale,
                y: offsetY + (rect.minY - bounds.minY) * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )
        }
    }
}
