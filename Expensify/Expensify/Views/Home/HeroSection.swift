import SwiftUI

/// Edge-to-edge hero block at the top of the Home tab — purely
/// atmospheric, sets a tone before any data lands on the screen.
/// Inspired by Railway's iOS app: a soft purple→midnight gradient,
/// scattered "stars" overlaid via Canvas, and the existing
/// "transactions" title + greeting laid out at the bottom-left so
/// the gradient negative-space at the top reads as actual sky.
///
/// No images bundled — gradient + Canvas-drawn dots is enough to
/// signal "night sky" without an asset and works in both light
/// and dark mode.
struct HeroSection: View {
    /// Greeting line below the title — short, voice-driven.
    let greeting: String
    /// Optional inline count rendered next to the page title
    /// ("transactions 64"). Hidden when nil.
    let inlineCount: Int?

    /// Pseudorandom but stable star positions. Computed once per
    /// view init so the stars don't reshuffle on every body
    /// invocation. We seed deterministically so two adjacent
    /// renders show the same layout.
    private let stars: [Star] = HeroSection.makeStars(count: 36, seed: 17)

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 1. Gradient background — adapts to light/dark.
            heroGradient

            // 2. Star field — Canvas is cheap; redraws are stable
            //    because positions are pre-computed.
            Canvas { context, size in
                for star in stars {
                    let x = star.x * size.width
                    let y = star.y * size.height
                    let rect = CGRect(
                        x: x - star.radius / 2,
                        y: y - star.radius / 2,
                        width: star.radius,
                        height: star.radius
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(.white.opacity(star.opacity))
                    )
                }
            }
            .allowsHitTesting(false)

            // 3. Foreground text — pinned to bottom-leading so the
            //    star field gets the upper two-thirds of the hero.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("transactions")
                        .font(AppFont.pageTitle)
                        .foregroundStyle(.white)
                    if let n = inlineCount {
                        Text("\(n)")
                            .font(.system(size: 24, weight: .regular, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .monospacedDigit()
                    }
                }
                Text(greeting)
                    .font(AppFont.rowSubtitle)
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipped()
    }

    // MARK: - Gradient

    /// Two-stop gradient: deep plum top, warm dusk bottom. In light
    /// mode it eases into a softer pastel sky so the hero still reads
    /// as atmospheric without going pitch-black.
    @ViewBuilder
    private var heroGradient: some View {
        LinearGradient(
            colors: [
                Color.dynamic(
                    light: Color(red: 0.38, green: 0.36, blue: 0.55),
                    dark:  Color(red: 0.09, green: 0.08, blue: 0.18)
                ),
                Color.dynamic(
                    light: Color(red: 0.62, green: 0.48, blue: 0.55),
                    dark:  Color(red: 0.28, green: 0.16, blue: 0.30)
                ),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Star field

    private struct Star {
        let x: Double
        let y: Double
        let radius: Double
        let opacity: Double
    }

    /// Seeded LCG so the same `seed` always produces the same layout.
    /// Avoids the "stars jump around on every redraw" tic that a
    /// naive Double.random() would cause.
    private static func makeStars(count: Int, seed: UInt64) -> [Star] {
        var rng = SeededRandom(seed: seed)
        return (0..<count).map { _ in
            Star(
                x: rng.nextDouble(),
                // Bias stars toward the top 70% of the hero — keeps
                // the area behind the title block free of clutter.
                y: rng.nextDouble() * 0.7,
                radius: 1.0 + rng.nextDouble() * 1.6,
                opacity: 0.25 + rng.nextDouble() * 0.55
            )
        }
    }

    private struct SeededRandom {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0xdead_beef : seed }
        mutating func nextDouble() -> Double {
            // Simple xorshift64.
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}

#Preview {
    VStack(spacing: 0) {
        HeroSection(
            greeting: "good morning. june is at ₹29,413. quietly tracking.",
            inlineCount: 64
        )
        Spacer()
    }
    .background(AppColor.canvas)
}
