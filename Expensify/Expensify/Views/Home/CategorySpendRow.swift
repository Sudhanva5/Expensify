import SwiftUI

/// What a tapped spend tile drills into — either the combined credit-card
/// view or a single spending category.
enum SpendSelection: Identifiable, Hashable {
    case creditCards
    case category(Category)

    var id: String {
        switch self {
        case .creditCards: return "creditCards"
        case .category(let c): return c.rawValue
        }
    }
}

/// Horizontal strip of spend tiles shown under the wallet on Home.
///
/// First tile is the COMBINED credit-card spend (across every `card_*`
/// instrument) — this replaces the old per-card instrument dock, which
/// broke spend out card-by-card. The remaining tiles are per-category
/// spend, each with its bundled illustration. Horizontally scrollable.
struct CategorySpendRow: View {
    let creditCardTotal: Decimal
    /// Pre-filtered + sorted (high→low) category spends to render.
    let categories: [(category: Category, total: Decimal)]
    /// Called when a tile is tapped — drives navigation to its detail.
    var onSelect: (SpendSelection) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Button { onSelect(.creditCards) } label: {
                    tile(artwork: .image("CatCreditCards"),
                         name: "Credit Cards",
                         total: creditCardTotal)
                }
                .buttonStyle(.plain)

                ForEach(categories, id: \.category) { item in
                    Button { onSelect(.category(item.category)) } label: {
                        tile(artwork: item.category.spendImageName.map(Artwork.image)
                                      ?? .symbol(item.category.symbolName),
                             name: item.category.shortName,
                             total: item.total)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 2)
        }
    }

    // MARK: - Tile

    private enum Artwork {
        case image(String)   // asset-catalog name
        case symbol(String)  // SF Symbol
    }

    private func tile(artwork: Artwork, name: String, total: Decimal) -> some View {
        HStack(spacing: 9) {
            // No box behind the artwork — the illustration sits directly on
            // the card.
            artworkView(artwork)
                .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
                Text(formatRupees(total))
                    .font(.system(size: 17, weight: .bold).monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(width: 156)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private func artworkView(_ artwork: Artwork) -> some View {
        switch artwork {
        case .image(let name):
            Image(name)
                .resizable()
                .scaledToFit()
        case .symbol(let symbol):
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppColor.textSecondary)
        }
    }

    /// "₹4,234" — Indian grouping, no decimals.
    private func formatRupees(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = 0
        return "₹" + (f.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)")
    }
}

extension Category {
    /// Asset-catalog name for the spend-tile illustration, or nil for
    /// categories without bundled art (Personal Transfer).
    var spendImageName: String? {
        switch self {
        case .travel:        return "CatTravel"
        case .food:          return "CatFood"
        case .groceries:     return "CatGroceries"
        case .entertainment: return "CatEntertainment"
        case .shopping:      return "CatShopping"
        case .investments:   return "CatInvestments"
        case .subscriptions: return "CatSubscriptions"
        case .personalTransfer: return "CatP2P"
        }
    }
}

#Preview {
    CategorySpendRow(
        creditCardTotal: 18_540,
        categories: [
            (.food, 4_234),
            (.shopping, 3_110),
            (.travel, 2_040),
            (.subscriptions, 899),
        ]
    )
    .padding(.vertical)
    .background(AppColor.canvas)
}
