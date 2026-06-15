import SwiftUI

/// Central design tokens for the workstation.
///
/// The look is inspired by Arc / Linear: deep ambient gradient depth,
/// translucent dark "glass" cards, restrained accents, tasteful motion.
/// These are tokens only — no view logic lives here.
enum Theme {

    // MARK: Canvas backdrop

    /// Deep ambient gradient that gives the infinite canvas a sense of depth.
    static let canvasGradient = LinearGradient(
        colors: [
            Color(red: 0.05, green: 0.06, blue: 0.11),
            Color(red: 0.07, green: 0.08, blue: 0.15),
            Color(red: 0.04, green: 0.05, blue: 0.09)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Soft colored glows layered over the gradient for the "wow" depth.
    static let glowPrimary = Color(red: 0.28, green: 0.36, blue: 0.85).opacity(0.30)
    static let glowSecondary = Color(red: 0.16, green: 0.55, blue: 0.50).opacity(0.22)

    /// Dot-grid color drawn across the infinite canvas.
    static let gridDot = Color.white.opacity(0.055)
    static let gridSpacing: CGFloat = 28

    // MARK: Glass cards

    static let cardFill = Color(red: 0.06, green: 0.07, blue: 0.11).opacity(0.72)
    static let cardStroke = Color.white.opacity(0.10)
    static let cardStrokeSelected = Color(red: 0.40, green: 0.55, blue: 1.0).opacity(0.9)
    static let cardHeaderFill = Color.white.opacity(0.04)
    static let cardShadow = Color.black.opacity(0.45)

    static let cardCornerRadius: CGFloat = 16
    static let cardHeaderHeight: CGFloat = 38

    // MARK: Text

    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    // MARK: Chrome (toolbar / sidebar / command bar)

    static let chromeFill = Color(red: 0.08, green: 0.09, blue: 0.13).opacity(0.78)
    static let chromeStroke = Color.white.opacity(0.10)
    static let accent = Color(red: 0.40, green: 0.55, blue: 1.0)

    // MARK: Camera limits

    static let minZoom: CGFloat = 0.30
    static let maxZoom: CGFloat = 2.2

    // MARK: Panel sizing
    // Cards spawn at a MODEST size (the backdrop stays visible around
    // them); freely draggable/resizable afterward. Two comfortably fit side-by-side.
    static let defaultPanelSize = CGSize(width: 600, height: 420)   // tidy grid fallback
    static let minPanelSize = CGSize(width: 340, height: 240)
    // Max width kept moderate (~85-col terminal) so a wide window fits another
    // column instead of stretching two cards across the whole screen.
    static let maxPanelSize = CGSize(width: 600, height: 520)
    static let panelWidthFraction: CGFloat = 0.38    // of viewport width
    static let panelHeightFraction: CGFloat = 0.50   // of viewport height
}

/// The lifecycle status surfaced in a panel header.
/// Color is intentionally tasteful, never neon.
extension SessionStatus {
    var tint: Color {
        switch self {
        case .idle:    return Color.white.opacity(0.45)
        case .working: return Color(red: 0.36, green: 0.80, blue: 0.52)
        case .waiting: return Color(red: 0.95, green: 0.74, blue: 0.32)
        case .blocked: return Color(red: 0.98, green: 0.56, blue: 0.26)   // urgent orange — asking you
        case .error:   return Color(red: 0.95, green: 0.42, blue: 0.42)
        case .done:    return Color(red: 0.45, green: 0.62, blue: 1.0)
        }
    }
}

extension AgentKind {
    var tint: Color {
        switch self {
        case .claude:  return Color(red: 0.83, green: 0.52, blue: 0.34) // warm Claude amber
        case .codex:   return Color(red: 0.52, green: 0.78, blue: 0.70) // cool Codex teal
        case .shell:   return Color.white.opacity(0.6)
        }
    }

    var glyph: String {
        switch self {
        case .claude: return "sparkle"
        case .codex:  return "chevron.left.forwardslash.chevron.right"
        case .shell:  return "terminal"
        }
    }
}
