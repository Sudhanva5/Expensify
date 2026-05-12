import SwiftUI

/// Color palette. Warm-tinted neutrals — every gray has a hint of the same
/// warm hue so the surface feels like a single material. Saturated colors
/// are reserved for signal: inflow green, tap-affordance blue.
///
/// Designed for a light surface. If we ever go dark, this whole enum needs
/// a companion table.
enum AppColor {
    /// Page background — barely-warm off-white. Slightly warmer than the
    /// system default to feel less clinical.
    static let canvas = Color(red: 0.985, green: 0.978, blue: 0.968)

    /// A raised surface, used sparingly (settings sections, top of
    /// scrollable surfaces). Slightly lighter than canvas.
    static let surface = Color.white

    /// Primary text — near-black with a warm tint, never pure black.
    static let textPrimary = Color(red: 0.13, green: 0.115, blue: 0.10)

    /// Secondary text — for labels, subtitles, dates.
    static let textSecondary = Color(red: 0.50, green: 0.46, blue: 0.42)

    /// Tertiary text — used for de-emphasized info (the ".00" decimal,
    /// hairline labels).
    static let textTertiary = Color(red: 0.70, green: 0.66, blue: 0.62)

    /// Hairline divider color. Almost invisible but enough to separate
    /// sections when we need it.
    static let hairline = Color(red: 0.90, green: 0.87, blue: 0.84)

    /// Subtle background for avatars without logos (initials). Slightly
    /// warmer than the canvas.
    static let avatarFill = Color(red: 0.94, green: 0.90, blue: 0.85)

    /// Inflow accent. Used only for positive amounts (money received).
    /// Not too vivid — readable next to body text.
    static let inflow = Color(red: 0.11, green: 0.50, blue: 0.32)

    /// Tap-affordance accent. Used for things you can tap that open Maps.
    static let tap = Color(red: 0.28, green: 0.43, blue: 0.88)
}

/// Typography. iOS native SF Pro family is the right call here — Apple
/// designed it for exactly this kind of UI. We use the rounded variant on
/// numbers and the rest is SF Pro with explicit weights.
enum AppFont {
    static let pageTitle: Font = .system(size: 32, weight: .bold)
    static let sectionLabel: Font = .system(size: 11, weight: .semibold)
        .smallCaps()
    static let rowTitle: Font = .system(size: 16, weight: .semibold)
    static let rowSubtitle: Font = .system(size: 13, weight: .regular)
    static let caption: Font = .system(size: 11, weight: .regular)
    static let bigNumber: Font = .system(size: 28, weight: .semibold, design: .rounded)
        .monospacedDigit()
    static let rowAmount: Font = .system(size: 16, weight: .semibold, design: .rounded)
        .monospacedDigit()
    static let amountDecimal: Font = .system(size: 13, weight: .semibold, design: .rounded)
        .monospacedDigit()
    static let chipLabel: Font = .system(size: 12, weight: .medium)
}
