import SwiftUI

/// Transaction row. Cred-inspired, restrained.
///
///   ○  Merchant Name                                  ₹547.00
///       food · 📍 bengaluru                           9 may '26
///
/// Layout:
///   • Avatar (favicon or initials) on the left
///   • Top: merchant name (left) + amount (right)
///   • Bottom-left: inline "category · location" — category greyed,
///     location in tap-blue (tap to open Maps). No tags, no pills.
///   • Bottom-right: small tertiary date
///
/// Color is reserved for signal: green for inflows (handled by
/// `AmountText`), blue for the tappable location text.
struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MerchantAvatar(merchantName: transaction.displayMerchant, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.displayMerchant)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                metaLine
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

    /// Inline "category · location" — both as plain text, only the
    /// location carries a hint of blue + a tap target.
    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(categoryText)
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textSecondary)

            if let city = locationText {
                Text("·")
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textTertiary)

                if transaction.hasCoordinates,
                   let lat = transaction.locationLat,
                   let lng = transaction.locationLng {
                    Button {
                        MapsLinker.open(latitude: lat, longitude: lng, label: transaction.displayMerchant)
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 10, weight: .medium))
                            Text(city.lowercased())
                                .font(.system(size: 13))
                                .lineLimit(1)
                        }
                        .foregroundStyle(AppColor.tap)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(city.lowercased())
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
    }

    private var categoryText: String {
        transaction.category?.shortName.lowercased() ?? "uncategorized"
    }

    private var locationText: String? {
        // Prefer city; fall back to coords; nothing if the transaction
        // has no location concept (autopay / inflow).
        if let city = transaction.locationCity, !city.isEmpty {
            return city
        }
        if let label = transaction.locationLabel {
            return label
        }
        return nil
    }

    /// Compact date — "9 May '26".
    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM ''yy"
        return df.string(from: transaction.occurredAt).lowercased()
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
