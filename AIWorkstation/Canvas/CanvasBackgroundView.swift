import SwiftUI

/// The infinite-canvas backdrop. Renders one of the selectable themes; backdrops
/// drift subtly with the camera (parallax) but do not scale with zoom — the scene
/// is a fixed ambience, not a zoomable object.
struct CanvasBackgroundView: View {
    let theme: CanvasTheme
    let camera: Camera

    var body: some View {
        Group {
            switch theme {
            case .minimal:     MinimalBackground(camera: camera)
            case .liquidGlass: LiquidGlassBackground(camera: camera)
            case .nature:      NatureBackground(camera: camera)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Minimal: gradient + ambient glows + dot grid

private struct MinimalBackground: View {
    let camera: Camera

    var body: some View {
        ZStack {
            Theme.canvasGradient

            RadialGradient(colors: [Theme.glowPrimary, .clear],
                           center: .topLeading, startRadius: 0, endRadius: 620)
                .offset(x: camera.pan.width * 0.04, y: camera.pan.height * 0.04)
                .blendMode(.screen)

            RadialGradient(colors: [Theme.glowSecondary, .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 680)
                .offset(x: camera.pan.width * 0.03, y: camera.pan.height * 0.03)
                .blendMode(.screen)

            DotGrid(camera: camera)
        }
    }
}

private struct DotGrid: View {
    let camera: Camera

    var body: some View {
        Canvas { context, size in
            let spacing = Theme.gridSpacing * camera.zoom
            guard spacing >= 6 else { return }

            let dotRadius: CGFloat = max(0.6, 1.1 * camera.zoom)
            let startX = camera.pan.width.truncatingRemainder(dividingBy: spacing)
            let startY = camera.pan.height.truncatingRemainder(dividingBy: spacing)

            var y = startY - spacing
            while y < size.height + spacing {
                var x = startX - spacing
                while x < size.width + spacing {
                    let rect = CGRect(x: x - dotRadius, y: y - dotRadius,
                                      width: dotRadius * 2, height: dotRadius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(Theme.gridDot))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

// MARK: - Liquid Glass: futuristic iridescent fluid + glass sheen

private struct LiquidGlassBackground: View {
    let camera: Camera

    private struct Blob { let color: Color; let center: UnitPoint; let radius: CGFloat; let parallax: CGFloat }

    private let blobs: [Blob] = [
        Blob(color: Color(red: 0.22, green: 0.85, blue: 0.95).opacity(0.34), center: .init(x: 0.22, y: 0.20), radius: 760, parallax: 0.06),
        Blob(color: Color(red: 0.55, green: 0.32, blue: 0.98).opacity(0.32), center: .init(x: 0.80, y: 0.28), radius: 820, parallax: 0.05),
        Blob(color: Color(red: 0.95, green: 0.35, blue: 0.78).opacity(0.22), center: .init(x: 0.66, y: 0.80), radius: 720, parallax: 0.045),
        Blob(color: Color(red: 0.20, green: 0.52, blue: 1.0).opacity(0.30),  center: .init(x: 0.16, y: 0.84), radius: 760, parallax: 0.055)
    ]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.03, blue: 0.07),
                         Color(red: 0.04, green: 0.05, blue: 0.11),
                         Color(red: 0.02, green: 0.02, blue: 0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            // Fluid iridescent color fields, softened for a "liquid" feel.
            ZStack {
                ForEach(0..<blobs.count, id: \.self) { i in
                    let b = blobs[i]
                    RadialGradient(colors: [b.color, .clear], center: b.center, startRadius: 0, endRadius: b.radius)
                        .offset(x: camera.pan.width * b.parallax, y: camera.pan.height * b.parallax)
                        .blendMode(.screen)
                }
            }
            .blur(radius: 30)

            // Glass specular sheen — a soft diagonal light sweep.
            LinearGradient(
                colors: [.clear, Color.white.opacity(0.10), .clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .blendMode(.softLight)

            // Vignette for depth.
            RadialGradient(colors: [.clear, Color.black.opacity(0.40)], center: .center, startRadius: 300, endRadius: 1050)
        }
    }
}

// MARK: - Nature: aurora sky over layered ridges

private struct NatureBackground: View {
    let camera: Camera

    var body: some View {
        ZStack(alignment: .bottom) {
            // Sky
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.05, blue: 0.13),
                         Color(red: 0.04, green: 0.09, blue: 0.18),
                         Color(red: 0.05, green: 0.15, blue: 0.18)],
                startPoint: .top, endPoint: .bottom
            )

            // Aurora band (upper third)
            RadialGradient(colors: [Color(red: 0.25, green: 0.85, blue: 0.6).opacity(0.30),
                                    Color(red: 0.30, green: 0.55, blue: 0.9).opacity(0.16), .clear],
                           center: .init(x: 0.45, y: 0.22), startRadius: 0, endRadius: 520)
                .offset(x: camera.pan.width * 0.03, y: camera.pan.height * 0.03)
                .blendMode(.screen)
                .blur(radius: 24)

            Starfield(camera: camera)

            // Layered ridges, far → near (bluer/lighter back, darker green front)
            RidgeShape(baseline: 0.58, amplitude: 40, frequency: 1.7, phase: 0.3)
                .fill(Color(red: 0.08, green: 0.16, blue: 0.28))
                .offset(x: camera.pan.width * 0.018)
            RidgeShape(baseline: 0.70, amplitude: 52, frequency: 1.2, phase: 2.0)
                .fill(Color(red: 0.06, green: 0.16, blue: 0.20))
                .offset(x: camera.pan.width * 0.03)
            RidgeShape(baseline: 0.84, amplitude: 46, frequency: 0.9, phase: 4.1)
                .fill(Color(red: 0.04, green: 0.14, blue: 0.11))
                .offset(x: camera.pan.width * 0.045)

            // Ground mist
            LinearGradient(colors: [.clear, Color(red: 0.10, green: 0.28, blue: 0.20).opacity(0.45)],
                           startPoint: .center, endPoint: .bottom)
                .blendMode(.screen)
        }
    }
}

// MARK: - Shared scene helpers

private struct Starfield: View {
    let camera: Camera

    var body: some View {
        Canvas { context, size in
            for star in Self.stars {
                let x = star.x * size.width + camera.pan.width * 0.015
                let y = star.y * size.height * 0.55 + camera.pan.height * 0.015
                let rect = CGRect(x: x, y: y, width: star.r, height: star.r)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(star.o)))
            }
        }
        .allowsHitTesting(false)
    }

    private struct Star { let x: CGFloat; let y: CGFloat; let r: CGFloat; let o: CGFloat }

    /// Deterministic starfield (stable across redraws) via a tiny seeded LCG.
    private static let stars: [Star] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((seed >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
        }
        return (0..<140).map { _ in
            Star(x: next(), y: next(), r: 0.6 + next() * 1.7, o: 0.2 + next() * 0.6)
        }
    }()
}

/// A filled silhouette with a soft wavy ridge line — used for layered hills/mountains.
private struct RidgeShape: Shape {
    var baseline: CGFloat   // fraction of height where the ridge sits
    var amplitude: CGFloat
    var frequency: CGFloat
    var phase: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topY = rect.height * baseline
        let steps = 56
        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: topY))
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.width * t
            // Two summed sines for a more organic ridge.
            let y = topY
                + sin(t * .pi * 2 * frequency + phase) * amplitude
                + sin(t * .pi * 2 * frequency * 2.3 + phase * 1.7) * amplitude * 0.35
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}
