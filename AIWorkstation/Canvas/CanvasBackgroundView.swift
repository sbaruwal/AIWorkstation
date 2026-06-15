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
            case .minimal:    MinimalBackground(camera: camera)
            case .futuristic: FuturisticBackground(camera: camera)
            case .nature:     NatureBackground(camera: camera)
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

// MARK: - Futuristic: deep-space cockpit with a tactical HUD overlay

private struct FuturisticBackground: View {
    let camera: Camera

    var body: some View {
        ZStack {
            // Deep hull / space gradient.
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.05, blue: 0.10),
                         Color(red: 0.05,  green: 0.07, blue: 0.13),
                         Color(red: 0.02,  green: 0.03, blue: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )

            Starfield(camera: camera)

            // Distant planet with an atmospheric rim-light (lower-right, parallax).
            GeometryReader { geo in
                let d = max(geo.size.width, geo.size.height) * 0.85
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(red: 0.10, green: 0.14, blue: 0.20),
                                 Color(red: 0.03, green: 0.05, blue: 0.09)],
                        center: .init(x: 0.36, y: 0.34), startRadius: 0, endRadius: d * 0.62))
                    .overlay(
                        Circle().strokeBorder(
                            AngularGradient(colors: [
                                Color(red: 0.30, green: 0.85, blue: 0.95).opacity(0.0),
                                Color(red: 0.30, green: 0.85, blue: 0.95).opacity(0.55),
                                Color(red: 1.0,  green: 0.70, blue: 0.40).opacity(0.35),
                                Color(red: 0.30, green: 0.85, blue: 0.95).opacity(0.0)],
                                center: .center),
                            lineWidth: 2.5)
                            .blur(radius: 1.5)
                    )
                    .frame(width: d, height: d)
                    .position(x: geo.size.width * 0.9, y: geo.size.height * 1.04)
                    .offset(x: camera.pan.width * 0.02, y: camera.pan.height * 0.02)
            }

            // Ambient HUD glows — amber + teal.
            RadialGradient(colors: [Color(red: 1.0, green: 0.68, blue: 0.35).opacity(0.16), .clear],
                           center: .init(x: 0.78, y: 0.20), startRadius: 0, endRadius: 460)
                .offset(x: camera.pan.width * 0.03, y: camera.pan.height * 0.03)
                .blendMode(.screen)
            RadialGradient(colors: [Color(red: 0.25, green: 0.78, blue: 0.92).opacity(0.18), .clear],
                           center: .init(x: 0.18, y: 0.82), startRadius: 0, endRadius: 520)
                .offset(x: camera.pan.width * 0.025, y: camera.pan.height * 0.025)
                .blendMode(.screen)

            // Fixed cockpit HUD overlay (tactical grid, perspective floor, brackets, reticle).
            HUDOverlay()

            // Subtle vignette.
            RadialGradient(colors: [.clear, Color.black.opacity(0.42)], center: .center, startRadius: 320, endRadius: 1080)
        }
    }
}

/// Vector HUD drawn over the scene like cockpit glass — fixed (no parallax) so it
/// reads as a heads-up display you're looking *through*.
private struct HUDOverlay: View {
    private let teal = Color(red: 0.31, green: 0.82, blue: 0.90)
    private let amber = Color(red: 1.0, green: 0.69, blue: 0.38)

    var body: some View {
        Canvas { ctx, size in
            // 1) Faint tactical grid.
            var grid = Path()
            let step: CGFloat = 70
            var x = step
            while x < size.width { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y = step
            while y < size.height { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(grid, with: .color(teal.opacity(0.045)), lineWidth: 0.5)

            // 2) Perspective "floor" grid receding to a vanishing point — the sci-fi cue.
            let vp = CGPoint(x: size.width * 0.5, y: size.height * 0.46)
            var floor = Path()
            var fx: CGFloat = 0
            while fx <= size.width { floor.move(to: CGPoint(x: fx, y: size.height)); floor.addLine(to: vp); fx += 110 }
            var t: CGFloat = 0.10
            while t < 1.0 {
                let yy = vp.y + (size.height - vp.y) * t * t   // ease so lines bunch near the horizon
                floor.move(to: CGPoint(x: 0, y: yy)); floor.addLine(to: CGPoint(x: size.width, y: yy))
                t += 0.14
            }
            ctx.stroke(floor, with: .color(teal.opacity(0.06)), lineWidth: 0.5)

            // 3) Corner brackets.
            let m: CGFloat = 16, arm: CGFloat = 26
            var br = Path()
            br.move(to: CGPoint(x: m, y: m + arm)); br.addLine(to: CGPoint(x: m, y: m)); br.addLine(to: CGPoint(x: m + arm, y: m))
            br.move(to: CGPoint(x: size.width - m - arm, y: m)); br.addLine(to: CGPoint(x: size.width - m, y: m)); br.addLine(to: CGPoint(x: size.width - m, y: m + arm))
            br.move(to: CGPoint(x: m, y: size.height - m - arm)); br.addLine(to: CGPoint(x: m, y: size.height - m)); br.addLine(to: CGPoint(x: m + arm, y: size.height - m))
            br.move(to: CGPoint(x: size.width - m - arm, y: size.height - m)); br.addLine(to: CGPoint(x: size.width - m, y: size.height - m)); br.addLine(to: CGPoint(x: size.width - m, y: size.height - m - arm))
            ctx.stroke(br, with: .color(teal.opacity(0.5)), lineWidth: 1.5)

            // 4) Targeting reticle (upper-right).
            let rc = CGPoint(x: size.width * 0.8, y: size.height * 0.2)
            var ring = Path(); ring.addEllipse(in: CGRect(x: rc.x - 28, y: rc.y - 28, width: 56, height: 56))
            ctx.stroke(ring, with: .color(amber.opacity(0.6)), lineWidth: 1)
            var ticks = Path()
            ticks.move(to: CGPoint(x: rc.x, y: rc.y - 34)); ticks.addLine(to: CGPoint(x: rc.x, y: rc.y - 22))
            ticks.move(to: CGPoint(x: rc.x, y: rc.y + 22)); ticks.addLine(to: CGPoint(x: rc.x, y: rc.y + 34))
            ticks.move(to: CGPoint(x: rc.x - 34, y: rc.y)); ticks.addLine(to: CGPoint(x: rc.x - 22, y: rc.y))
            ticks.move(to: CGPoint(x: rc.x + 22, y: rc.y)); ticks.addLine(to: CGPoint(x: rc.x + 34, y: rc.y))
            ctx.stroke(ticks, with: .color(amber.opacity(0.6)), lineWidth: 1)
            ctx.fill(Path(ellipseIn: CGRect(x: rc.x - 2.5, y: rc.y - 2.5, width: 5, height: 5)), with: .color(amber.opacity(0.85)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Nature: a user-supplied photo (Backdrops/nature.*) over a dark scrim,
// falling back to an original procedural scene when no image is present.

private struct NatureBackground: View {
    let camera: Camera

    /// Loaded once. A photo at `Backdrops/nature.{jpg,jpeg,png,heic}` wins; otherwise
    /// the procedural scene is used (so the repo ships with no bundled/licensed image).
    private static let photo: NSImage? = {
        let dir = WorkspaceStore.shared.backdropsDir
        for name in ["nature.jpg", "nature.jpeg", "nature.png", "nature.heic"] {
            if let img = NSImage(contentsOfFile: dir.appendingPathComponent(name).path) { return img }
        }
        return nil
    }()

    var body: some View {
        if let photo = Self.photo {
            ZStack {
                GeometryReader { geo in
                    Image(nsImage: photo)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width * 1.12, height: geo.size.height * 1.12)
                        .offset(x: camera.pan.width * 0.02 - geo.size.width * 0.06,
                                y: camera.pan.height * 0.02 - geo.size.height * 0.06)
                        .clipped()
                }
                // Scrim so the glass cards + text stay legible over a bright photo.
                LinearGradient(colors: [Color.black.opacity(0.42), Color.black.opacity(0.12), Color.black.opacity(0.50)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [.clear, Color.black.opacity(0.32)], center: .center, startRadius: 260, endRadius: 1000)
            }
        } else {
            ProceduralNature(camera: camera)
        }
    }
}

// MARK: - Procedural nature fallback: aurora sky over layered ridges

private struct ProceduralNature: View {
    let camera: Camera

    var body: some View {
        ZStack(alignment: .bottom) {
            // Sky — deep night-blue up top, easing into a teal horizon.
            LinearGradient(
                colors: [Color(red: 0.03, green: 0.05, blue: 0.14),
                         Color(red: 0.04, green: 0.10, blue: 0.20),
                         Color(red: 0.06, green: 0.17, blue: 0.20)],
                startPoint: .top, endPoint: .bottom
            )

            Starfield(camera: camera)

            // Warm low sun/moon glow near the horizon — the anchor that makes it read
            // as a real landscape rather than an abstract gradient.
            RadialGradient(colors: [Color(red: 1.0, green: 0.84, blue: 0.55).opacity(0.26),
                                    Color(red: 0.95, green: 0.58, blue: 0.40).opacity(0.10), .clear],
                           center: .init(x: 0.66, y: 0.56), startRadius: 0, endRadius: 360)
                .offset(x: camera.pan.width * 0.02, y: camera.pan.height * 0.02)
                .blendMode(.screen)
                .blur(radius: 18)

            // Faint aurora veil, higher up.
            RadialGradient(colors: [Color(red: 0.25, green: 0.85, blue: 0.6).opacity(0.18), .clear],
                           center: .init(x: 0.40, y: 0.20), startRadius: 0, endRadius: 480)
                .offset(x: camera.pan.width * 0.03, y: camera.pan.height * 0.03)
                .blendMode(.screen)
                .blur(radius: 30)

            // Atmospheric haze band sitting along the ridgeline (distance softening).
            LinearGradient(colors: [.clear, Color(red: 0.5, green: 0.7, blue: 0.75).opacity(0.10), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 240)
                .frame(maxHeight: .infinity, alignment: .center)
                .offset(y: 30)

            // Layered ridges, far → near. Atmospheric perspective: hazy blue-grey in the
            // distance, deep green up close — far layers lose contrast like real haze.
            RidgeShape(baseline: 0.56, amplitude: 38, frequency: 1.7, phase: 0.3)
                .fill(Color(red: 0.17, green: 0.30, blue: 0.40))
                .offset(x: camera.pan.width * 0.018)
            RidgeShape(baseline: 0.70, amplitude: 52, frequency: 1.2, phase: 2.0)
                .fill(Color(red: 0.10, green: 0.22, blue: 0.27))
                .offset(x: camera.pan.width * 0.03)
            RidgeShape(baseline: 0.85, amplitude: 48, frequency: 0.9, phase: 4.1)
                .fill(Color(red: 0.05, green: 0.15, blue: 0.12))
                .offset(x: camera.pan.width * 0.045)

            // Ground mist.
            LinearGradient(colors: [.clear, Color(red: 0.12, green: 0.30, blue: 0.22).opacity(0.5)],
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
