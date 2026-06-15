import SwiftUI

/// Card outline that adapts to the canvas theme: rounded for Minimal/Nature, and a
/// sharp panel with a beveled top-right corner for Futuristic (a tactical-HUD look).
struct ThemedCardShape: Shape {
    var radius: CGFloat
    var topRightCut: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let lim = min(rect.width, rect.height) / 2
        let r = min(radius, lim)
        let cut = min(topRightCut, lim)

        p.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        if cut > 0 {                                   // beveled top-right (Futuristic)
            p.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + cut))
        } else {                                       // rounded top-right
            p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension CanvasTheme {
    /// Per-theme card geometry: a near-sharp, beveled panel for Futuristic; soft
    /// rounded for Minimal/Nature.
    var cardRadius: CGFloat { self == .futuristic ? 3 : 16 }
    var cardCut: CGFloat { self == .futuristic ? 16 : 0 }
    var cardShape: ThemedCardShape { ThemedCardShape(radius: cardRadius, topRightCut: cardCut) }
}

/// Theme-specific card border. Futuristic: amber top edge + teal left edge (HUD).
/// Nature: a soft turquoise edge-glow. Minimal: a clean hairline. Selection brightens.
struct ThemedCardBorder: View {
    let theme: CanvasTheme
    let isSelected: Bool
    let accent: Color

    private let amber = Color(red: 1.0, green: 0.69, blue: 0.38)
    private let teal  = Color(red: 0.31, green: 0.82, blue: 0.90)
    private let mist  = Color(red: 0.74, green: 0.93, blue: 0.87)

    var body: some View {
        content.allowsHitTesting(false)   // decorative only — never intercept clicks/drags
    }

    @ViewBuilder private var content: some View {
        switch theme {
        case .futuristic:
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let cut = theme.cardCut
                ZStack {
                    theme.cardShape.stroke(Color.white.opacity(isSelected ? 0.16 : 0.08), lineWidth: 1)
                    Path { p in                          // amber top edge, following the bevel
                        p.move(to: CGPoint(x: 2, y: 0.75))
                        p.addLine(to: CGPoint(x: w - cut, y: 0.75))
                        p.addLine(to: CGPoint(x: w - 0.75, y: cut))
                    }
                    .stroke(amber.opacity(isSelected ? 1 : 0.85), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                    Path { p in                          // teal left edge
                        p.move(to: CGPoint(x: 0.75, y: 2))
                        p.addLine(to: CGPoint(x: 0.75, y: h - 2))
                    }
                    .stroke(teal.opacity(isSelected ? 1 : 0.6), lineWidth: 1.5)
                }
            }
        case .nature:
            ZStack {
                ZStack {
                    // Misty crown — a soft spray of light across the top.
                    LinearGradient(colors: [mist.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 38)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    // Water cascade — a turquoise stream down the left edge (soft glow + core).
                    LinearGradient(colors: [accent.opacity(0.30), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    LinearGradient(colors: [accent.opacity(0.95), accent.opacity(0.08)], startPoint: .top, endPoint: .bottom)
                        .frame(width: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .clipShape(theme.cardShape)

                theme.cardShape
                    .stroke(accent.opacity(isSelected ? 0.95 : 0.4), lineWidth: isSelected ? 1.6 : 1)
                    .shadow(color: accent.opacity(isSelected ? 0.5 : 0.2), radius: isSelected ? 7 : 4)
            }
        case .minimal:
            theme.cardShape
                .stroke(isSelected ? accent.opacity(0.9) : Theme.cardStroke, lineWidth: isSelected ? 1.5 : 1)
        }
    }
}

extension View {
    /// Clip to the theme's card shape and draw its theme-specific border.
    func themedCardFrame(_ theme: CanvasTheme, isSelected: Bool = false, accent: Color) -> some View {
        clipShape(theme.cardShape)
            .overlay(ThemedCardBorder(theme: theme, isSelected: isSelected, accent: accent))
    }
}
