import SwiftUI

/// App-level light/dark preference (Settings → Appearance). The canvas itself is a
/// dark, themed surface by design; this primarily drives the system chrome
/// (menus, Settings, alerts, popovers). Defaults to `.dark` to preserve the app's
/// dark identity — choose `.system` to follow macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// `nil` → follow the system (no forced scheme).
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
