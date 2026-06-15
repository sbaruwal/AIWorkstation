import SwiftUI
import AppKit

/// Selectable canvas backdrops.
///
/// Swappable backdrops with original art (or, for Nature, a user-supplied photo).
/// Each theme also carries a **palette** so the theme flows through the glass cards
/// and the terminals (translucent, theme-tinted) — the whole scene retints to match.
enum CanvasTheme: String, CaseIterable, Identifiable, Hashable {
    case minimal
    case futuristic
    case nature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal:    return "Minimal"
        case .futuristic: return "Futuristic"
        case .nature:     return "Nature"
        }
    }

    var glyph: String {
        switch self {
        case .minimal:    return "circle.grid.2x2"
        case .futuristic: return "viewfinder"
        case .nature:     return "leaf"
        }
    }

    // MARK: Terminal palette (semi-translucent so the backdrop flows through)

    var terminalBackground: NSColor {
        switch self {
        case .minimal:    return NSColor(srgbRed: 0.05,  green: 0.06,  blue: 0.105, alpha: 0.58)   // cool slate
        case .futuristic: return NSColor(srgbRed: 0.03,  green: 0.045, blue: 0.072, alpha: 0.52)   // dark hull, HUD cast
        case .nature:     return NSColor(srgbRed: 0.02,  green: 0.115, blue: 0.105, alpha: 0.55)   // deep teal-forest (the lake)
        }
    }

    var terminalForeground: NSColor {
        switch self {
        case .minimal:    return NSColor(srgbRed: 0.87, green: 0.89, blue: 0.94, alpha: 1)
        case .futuristic: return NSColor(srgbRed: 0.80, green: 0.86, blue: 0.93, alpha: 1)
        case .nature:     return NSColor(srgbRed: 0.88, green: 0.95, blue: 0.91, alpha: 1)
        }
    }

    var terminalCaret: NSColor {
        switch self {
        case .minimal:    return NSColor(srgbRed: 0.40, green: 0.55, blue: 1.0,  alpha: 1)   // blue
        case .futuristic: return NSColor(srgbRed: 1.0,  green: 0.69, blue: 0.35, alpha: 1)   // amber HUD
        case .nature:     return NSColor(srgbRed: 0.18, green: 0.85, blue: 0.76, alpha: 1)   // turquoise water
        }
    }

    // MARK: Glass-card tint (overlaid on the within-window blur)

    var cardTint: Color {
        switch self {
        case .minimal:    return Color(red: 0.06, green: 0.07, blue: 0.12).opacity(0.50)
        case .futuristic: return Color(red: 0.04, green: 0.06, blue: 0.10).opacity(0.42)
        case .nature:     return Color(red: 0.02, green: 0.13, blue: 0.115).opacity(0.42)
        }
    }

    var accent: Color {
        switch self {
        case .minimal:    return Color(red: 0.40, green: 0.55, blue: 1.0)
        case .futuristic: return Color(red: 0.31, green: 0.82, blue: 0.90)   // teal HUD
        case .nature:     return Color(red: 0.16, green: 0.82, blue: 0.72)   // turquoise
        }
    }
}
