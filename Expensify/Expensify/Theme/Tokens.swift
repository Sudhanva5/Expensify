import SwiftUI
import UIKit

/// Color palette. Warm-tinted neutrals — every gray has a hint of the same
/// warm hue so the surface feels like a single material in both light and
/// dark mode. Saturated colors are reserved for signal: inflow green,
/// tap-affordance blue.
///
/// Every token is a dynamic color that resolves at render time based on
/// the active `userInterfaceStyle`. Per Apple HIG dark-mode guidance:
///   • Don't invert — design the dark palette as its own coherent
///     surface. The warm tint that defines our light mode carries
///     into dark as a warm near-black, not cold blue-black.
///   • Reduce saturation on the dark side; heavy chroma at low
///     luminance reads as garish.
///   • Lift accent brightness slightly in dark — green/blue glyphs
///     need extra punch against a near-black surface to keep WCAG
///     contrast at AA.
///   • Pure black (#000) is for OLED-power-savings apps; this is a
///     content app so we use a warm near-black instead.
///
/// Helper at bottom of file: `Color.dynamic(light:dark:)`.
enum AppColor {
    /// Page background.
    ///   light: barely-warm off-white, slightly warmer than system default
    ///   dark:  warm near-black (not pure black — pure black on OLED is
    ///          flat and loses our warmth identity)
    static let canvas = Color.dynamic(
        light: Color(red: 0.985, green: 0.978, blue: 0.968),
        dark:  Color(red: 0.090, green: 0.082, blue: 0.072)
    )

    /// A raised surface — settings sections, sheet bodies, the receipt
    /// card. Slightly lighter than canvas so layering reads visually.
    static let surface = Color.dynamic(
        light: Color.white,
        dark:  Color(red: 0.140, green: 0.128, blue: 0.115)
    )

    /// Primary text. Warm near-black in light; warm near-white in dark.
    static let textPrimary = Color.dynamic(
        light: Color(red: 0.130, green: 0.115, blue: 0.100),
        dark:  Color(red: 0.962, green: 0.948, blue: 0.918)
    )

    /// Secondary text — for labels, subtitles, dates. Both modes keep
    /// roughly 60% contrast against the canvas.
    static let textSecondary = Color.dynamic(
        light: Color(red: 0.500, green: 0.460, blue: 0.420),
        dark:  Color(red: 0.660, green: 0.622, blue: 0.575)
    )

    /// Tertiary text — for de-emphasized info (the ".00" decimal,
    /// hairline labels).
    static let textTertiary = Color.dynamic(
        light: Color(red: 0.700, green: 0.660, blue: 0.620),
        dark:  Color(red: 0.475, green: 0.445, blue: 0.412)
    )

    /// Hairline divider. Almost invisible but enough to separate sections.
    static let hairline = Color.dynamic(
        light: Color(red: 0.900, green: 0.870, blue: 0.840),
        dark:  Color(red: 0.215, green: 0.198, blue: 0.180)
    )

    /// Subtle background for avatars without logos (initials), category
    /// icons in pickers, etc. Slightly warmer than the canvas.
    static let avatarFill = Color.dynamic(
        light: Color(red: 0.940, green: 0.900, blue: 0.850),
        dark:  Color(red: 0.200, green: 0.182, blue: 0.162)
    )

    /// Inflow accent. Used only for positive amounts (money received).
    /// In dark mode we lift the brightness so the green reads against
    /// the near-black canvas without losing its grounded feel.
    static let inflow = Color.dynamic(
        light: Color(red: 0.110, green: 0.500, blue: 0.320),
        dark:  Color(red: 0.345, green: 0.770, blue: 0.530)
    )

    /// Tap-affordance accent. A saturated blue that signals "interactive"
    /// at a glance — toolbar buttons, avatar initials, selected category
    /// icons, the contact-pin glyph, the Maps button background.
    ///
    /// Light: a slightly warm, deep cobalt that holds its own against
    /// the off-white canvas without feeling generic-iOS-blue.
    /// Dark: lifted brighter blue so it stays legible at AA contrast
    /// against the near-black canvas.
    ///
    /// When used as a BACKGROUND (Maps button, instrument-dock selected
    /// chip), pair with `AppColor.canvas` as the foreground so the
    /// text stays readable in both modes — never `.white` literal.
    static let tap = Color.dynamic(
        light: Color(red: 0.280, green: 0.430, blue: 0.880),
        dark:  Color(red: 0.490, green: 0.620, blue: 0.980)
    )
}

extension Color {
    /// Build a dynamic Color that resolves at render time based on the
    /// active interface style. Wraps `UIColor(dynamicProvider:)` because
    /// SwiftUI's `Color` has no native light/dark initializer until
    /// iOS 18, and this pattern works on iOS 15+.
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
    }
}

/// Typography. iOS native SF Pro family throughout — Apple designed it for
/// exactly this kind of UI. SF Pro with explicit weights everywhere; numbers
/// add `.monospacedDigit()` so columns of amounts align. (No SF Pro Rounded —
/// its glyph set is missing ₹, which fell back to a mismatched font.)
enum AppFont {
    static let pageTitle: Font = .system(size: 32, weight: .bold)
    static let sectionLabel: Font = .system(size: 11, weight: .semibold)
        .smallCaps()
    static let rowTitle: Font = .system(size: 16, weight: .semibold)
    static let rowSubtitle: Font = .system(size: 13, weight: .regular)
    static let caption: Font = .system(size: 11, weight: .regular)
    static let bigNumber: Font = .system(size: 28, weight: .semibold)
        .monospacedDigit()
    static let rowAmount: Font = .system(size: 16, weight: .semibold)
        .monospacedDigit()
    static let amountDecimal: Font = .system(size: 13, weight: .semibold)
        .monospacedDigit()
    static let chipLabel: Font = .system(size: 12, weight: .medium)
}
