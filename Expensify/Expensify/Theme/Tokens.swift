import SwiftUI
import UIKit

/// Color palette. True neutrals — every gray is achromatic (R == G == B),
/// so no surface carries a hue of its own and the only color on screen is
/// signal: inflow green, tap-affordance blue, over-budget red.
///
/// These were warm-tinted (a brown cast through every gray) until it read
/// as sepia rather than as a material. Neutral grays were chosen at the
/// *same perceptual luminance* as the warm values they replaced, so the
/// contrast ratios that were tuned for AA are unchanged — only the hue is
/// gone. Keep it that way: a token whose channels aren't equal is a bug
/// unless it's an accent.
///
/// Every token is a dynamic color that resolves at render time based on
/// the active `userInterfaceStyle`. Per Apple HIG dark-mode guidance:
///   • Don't invert — design the dark palette as its own coherent
///     surface, not a mirror of light.
///   • Reduce saturation on the dark side; heavy chroma at low
///     luminance reads as garish.
///   • Lift accent brightness slightly in dark — green/blue glyphs
///     need extra punch against a near-black surface to keep WCAG
///     contrast at AA.
///   • Pure black (#000) is for OLED-power-savings apps; this is a
///     content app so we use a near-black instead.
///
/// Helper at bottom of file: `Color.dynamic(light:dark:)`.
enum AppColor {
    /// Page background.
    ///   light: neutral off-white, a shade below pure white so `surface`
    ///          (which IS pure white) can still lift off it
    ///   dark:  neutral near-black (not pure black — pure black on OLED
    ///          reads flat and kills the layering against `surface`)
    static let canvas = Color.dynamic(
        light: Color(red: 0.978, green: 0.978, blue: 0.978),
        dark:  Color(red: 0.083, green: 0.083, blue: 0.083)
    )

    /// A raised surface — settings sections, sheet bodies, the receipt
    /// card. Slightly lighter than canvas so layering reads visually.
    static let surface = Color.dynamic(
        light: Color.white,
        dark:  Color(red: 0.130, green: 0.130, blue: 0.130)
    )

    /// Primary text. Near-black in light; near-white in dark.
    static let textPrimary = Color.dynamic(
        light: Color(red: 0.117, green: 0.117, blue: 0.117),
        dark:  Color(red: 0.949, green: 0.949, blue: 0.949)
    )

    /// Secondary text — for labels, subtitles, dates. Both modes keep
    /// roughly 60% contrast against the canvas.
    static let textSecondary = Color.dynamic(
        light: Color(red: 0.466, green: 0.466, blue: 0.466),
        dark:  Color(red: 0.627, green: 0.627, blue: 0.627)
    )

    /// Tertiary text — for de-emphasized info (the ".00" decimal,
    /// hairline labels).
    static let textTertiary = Color.dynamic(
        light: Color(red: 0.666, green: 0.666, blue: 0.666),
        dark:  Color(red: 0.449, green: 0.449, blue: 0.449)
    )

    /// Hairline divider. Almost invisible but enough to separate sections.
    static let hairline = Color.dynamic(
        light: Color(red: 0.874, green: 0.874, blue: 0.874),
        dark:  Color(red: 0.200, green: 0.200, blue: 0.200)
    )

    /// Subtle background for avatars without logos (initials), category
    /// icons in pickers, etc. One step off the canvas so the circle reads
    /// as a filled shape rather than a hole.
    static let avatarFill = Color.dynamic(
        light: Color(red: 0.905, green: 0.905, blue: 0.905),
        dark:  Color(red: 0.184, green: 0.184, blue: 0.184)
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
    /// Light: a deep cobalt that holds its own against the off-white
    /// canvas without feeling generic-iOS-blue.
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
