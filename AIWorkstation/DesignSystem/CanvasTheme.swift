import SwiftUI
import AppKit

/// Selectable canvas backdrops.
///
/// Swappable backdrops with original art. Each theme also carries a **palette**
/// so the theme flows through the glass cards and the terminals (translucent,
/// theme-tinted) — the whole scene retints to match the chosen backdrop.
enum CanvasTheme: String, CaseIterable, Identifiable, Hashable {
    case minimal
    case liquidGlass
    case nature

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimal:     return "Minimal"
        case .liquidGlass: return "Liquid Glass"
        case .nature:      return "Nature"
        }
    }

    var glyph: String {
        switch self {
        case .minimal:     return "circle.grid.2x2"
        case .liquidGlass: return "drop.halffull"
        case .nature:      return "mountain.2"
        }
    }

    // MARK: Terminal palette (semi-translucent so the backdrop flows through)

    var terminalBackground: NSColor {
        switch self {
        case .minimal:     return NSColor(srgbRed: 0.05,  green: 0.06,  blue: 0.10,  alpha: 0.55)
        case .liquidGlass: return NSColor(srgbRed: 0.035, green: 0.06,  blue: 0.12,  alpha: 0.48)
        case .nature:      return NSColor(srgbRed: 0.03,  green: 0.075, blue: 0.065, alpha: 0.50)
        }
    }

    var terminalForeground: NSColor {
        switch self {
        case .minimal:     return NSColor(srgbRed: 0.87, green: 0.89, blue: 0.93, alpha: 1)
        case .liquidGlass: return NSColor(srgbRed: 0.84, green: 0.92, blue: 0.97, alpha: 1)
        case .nature:      return NSColor(srgbRed: 0.88, green: 0.93, blue: 0.88, alpha: 1)
        }
    }

    var terminalCaret: NSColor {
        switch self {
        case .minimal:     return NSColor(srgbRed: 0.40, green: 0.55, blue: 1.0,  alpha: 1)
        case .liquidGlass: return NSColor(srgbRed: 0.36, green: 0.86, blue: 0.96, alpha: 1)
        case .nature:      return NSColor(srgbRed: 0.46, green: 0.86, blue: 0.56, alpha: 1)
        }
    }

    // MARK: Glass-card tint (overlaid on the within-window blur)

    var cardTint: Color {
        switch self {
        case .minimal:     return Color(red: 0.06,  green: 0.07,  blue: 0.11).opacity(0.50)
        case .liquidGlass: return Color(red: 0.05,  green: 0.08,  blue: 0.15).opacity(0.42)
        case .nature:      return Color(red: 0.04,  green: 0.09,  blue: 0.085).opacity(0.44)
        }
    }

    var accent: Color {
        switch self {
        case .minimal:     return Color(red: 0.40, green: 0.55, blue: 1.0)
        case .liquidGlass: return Color(red: 0.36, green: 0.86, blue: 0.96)
        case .nature:      return Color(red: 0.46, green: 0.86, blue: 0.56)
        }
    }
}
