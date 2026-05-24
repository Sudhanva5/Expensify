import SwiftUI

/// User-controllable theme preference, persisted in UserDefaults.
///
///   • `.system`  follow the device-level Light/Dark setting (default)
///   • `.light`   force light regardless of device
///   • `.dark`    force dark regardless of device
///
/// Read via `@AppStorage("themePreference")` at the app root; apply to
/// the root view with `.preferredColorScheme(pref.colorScheme)`.
enum ThemePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    /// SwiftUI's `preferredColorScheme` accepts an optional ColorScheme —
    /// `nil` means "inherit from the device". That's how `.system`
    /// turns into the default behaviour without any extra wiring.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var label: String {
        switch self {
        case .system: return "system"
        case .light:  return "light"
        case .dark:   return "dark"
        }
    }

    /// Single source of truth for the @AppStorage key — keep both
    /// reader sites (root view + settings picker) referencing this
    /// constant so a typo can't quietly desync them.
    static let storageKey = "themePreference"
}
