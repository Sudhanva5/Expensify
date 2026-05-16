import SwiftUI

/// Compact picker shown in the bottom-sheet detail when the recategorize
/// pass found Places candidates near the transaction but couldn't pick
/// one confidently (ambiguous = multiple food/grocery places in same
/// building, etc.). Tap a row → optimistic re-tag via TransactionStore,
/// row updates instantly + backend persists in the background.
///
/// Rendered above the receipt card. Hidden once a Places resolution has
/// already been applied (`transaction.hasResolvedMerchant`).
struct NearbyPlacesPicker: View {
    let transactionId: String
    let suggestions: [PlaceSuggestion]

    @Environment(TransactionStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("nearby places")
                    .font(.system(size: 11, weight: .semibold).smallCaps())
                    .foregroundStyle(AppColor.textTertiary)
                Spacer()
                Text("tap to tag")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }

            VStack(spacing: 4) {
                ForEach(suggestions, id: \.name) { suggestion in
                    Button {
                        guard let cat = suggestion.resolvedCategory else { return }
                        Task {
                            await store.retag(transactionId: transactionId, to: cat)
                        }
                    } label: {
                        suggestionRow(suggestion)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func suggestionRow(_ s: PlaceSuggestion) -> some View {
        HStack(spacing: 10) {
            // Category icon (food fork, basket, popcorn, etc.) on a
            // warm-tinted square — visually matches the home row chip.
            Image(systemName: s.resolvedCategory?.symbolName ?? "questionmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .frame(width: 28, height: 28)
                .background(AppColor.avatarFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(s.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Text("\(s.distanceM)m · \(s.resolvedCategory?.shortName ?? s.category)")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppColor.textTertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

#Preview {
    NearbyPlacesPicker(
        transactionId: "preview-1",
        suggestions: [
            PlaceSuggestion(
                name: "Sri Vishnu Grand Veg",
                category: "Food",
                distanceM: 0,
                lat: 12.9046414,
                lng: 77.6758958,
                formattedAddress: "WM3G+V92, 1st Cross Rd, Kasavanahalli"
            ),
            PlaceSuggestion(
                name: "Vishnu Garden Bar and Restaurants",
                category: "Food",
                distanceM: 2,
                lat: 12.9046, lng: 77.6759,
                formattedAddress: nil
            ),
            PlaceSuggestion(
                name: "SRINIVASA SNACKS BAZAR",
                category: "Food",
                distanceM: 4,
                lat: 12.9046, lng: 77.6759,
                formattedAddress: nil
            )
        ]
    )
    .environment(TransactionStore())
    .padding()
    .background(AppColor.canvas)
}
