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
                Text("Nearby Places")
                    .font(.system(size: 11, weight: .semibold).smallCaps())
                    .foregroundStyle(AppColor.textTertiary)
                Spacer()
                Text("Tap to tag")
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }

            VStack(spacing: 4) {
                ForEach(suggestions, id: \.name) { suggestion in
                    Button {
                        guard let cat = suggestion.resolvedCategory else { return }
                        Task {
                            // Bulk-propagating apply: this row's
                            // merchantNormalized becomes the storefront
                            // name, AND every other row with the same
                            // VPA gets rewritten to match. The user's
                            // explicit ask — claiming a place once
                            // fixes their history.
                            await store.applyPlace(
                                transactionId: transactionId,
                                placesName: suggestion.name,
                                category: cat,
                                lat: suggestion.lat,
                                lng: suggestion.lng
                            )
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
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func suggestionRow(_ s: PlaceSuggestion) -> some View {
        HStack(spacing: 10) {
            // Custom category illustration (falls back to its SF Symbol),
            // in a circle — matches the edit sheet / budget rows.
            Group {
                if let cat = s.resolvedCategory, let asset = cat.spendImageName {
                    Image(asset).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: s.resolvedCategory?.symbolName ?? "mappin")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.textPrimary)
                }
            }
            .frame(width: 32, height: 32)
            .background(AppColor.avatarFill)
            .clipShape(Circle())

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
