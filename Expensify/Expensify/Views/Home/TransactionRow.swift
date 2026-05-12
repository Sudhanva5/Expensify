import SwiftUI

/// Transaction row. Cred-inspired, restrained color use.
///
///   ○ Avatar     Merchant Name                              ₹547.00
///                [🍴 food]  [📍 Bengaluru]                  9 may '26
///
/// Layout:
///   • Avatar (favicon or initials) on the left
///   • Top: merchant name (left) + amount (right)
///   • Bottom-left: category tag + location tag (both compact)
///   • Bottom-right: date in small tertiary text
///
/// Color is reserved for signal: green for inflows, blue for tappable
/// map affordances. Everything else stays in the warm-neutral palette.
struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MerchantAvatar(merchantName: transaction.displayMerchant, size: 44)

            VStack(alignment: .leading, spacing: 6) {
                Text(transaction.displayMerchant)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    if let category = transaction.category {
                        CategoryPill(category: category, compact: true)
                    }
                    if transaction.hasCoordinates,
                       let lat = transaction.locationLat,
                       let lng = transaction.locationLng {
                        LocationMapChip(
                            label: transaction.locationCity ?? transaction.locationLabel ?? "map",
                            latitude: lat,
                            longitude: lng,
                            merchantLabel: transaction.displayMerchant
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                AmountText(amount: transaction.amountInr, direction: transaction.direction)
                Text(dateString)
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Compact date — "9 May '26" — matches the reference's "11 May '26".
    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM ''yy"
        return df.string(from: transaction.occurredAt).lowercased()
    }
}

/// Small clickable map chip. Subtle blue (the only tap-affordance accent).
private struct LocationMapChip: View {
    let label: String
    let latitude: Double
    let longitude: Double
    let merchantLabel: String

    var body: some View {
        Button {
            MapsLinker.open(latitude: latitude, longitude: longitude, label: merchantLabel)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 9, weight: .semibold))
                Text(label.lowercased())
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(AppColor.tap)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(AppColor.tap.opacity(0.10))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    List {
        ForEach(MockData.transactions) { tx in
            TransactionRow(transaction: tx)
                .listRowSeparator(.hidden)
        }
    }
    .listStyle(.plain)
    .background(AppColor.canvas)
}
