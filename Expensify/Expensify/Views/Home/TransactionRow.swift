import SwiftUI

/// Transaction row used in the Home list and per-category detail. Layout:
///
///   ┌────┐   Merchant Name                       -₹547.00
///   │ 📍 │   [ 🍴 Food ]  [ 📍 Bengaluru ]   · 9 May 10:57
///   └────┘
///
/// Where:
///   • Left tile is the location pin (tappable → Apple Maps) when we have
///     coordinates; otherwise falls back to the category icon.
///   • Title is the resolved merchant name (via Places + Groq) when we have
///     one; otherwise the raw payee.
///   • Category pill below the title, with the same tint as the icon.
///   • Location chip (tappable → Maps too) sits next to the category pill.
///   • Amount is on the right, monospaced, signed.
struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            iconTile

            VStack(alignment: .leading, spacing: 6) {
                titleRow
                metaRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: - Pieces

    private var iconTile: some View {
        Group {
            if transaction.hasCoordinates,
               let lat = transaction.locationLat,
               let lng = transaction.locationLng {
                Button {
                    MapsLinker.open(latitude: lat, longitude: lng, label: transaction.displayMerchant)
                } label: {
                    iconTileContent(symbol: "mappin.and.ellipse", tint: .blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open in Maps")
            } else {
                iconTileContent(
                    symbol: transaction.category?.symbolName ?? "wallet.pass",
                    tint: transaction.category?.tint ?? .secondary
                )
            }
        }
    }

    @ViewBuilder
    private func iconTileContent(symbol: String, tint: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 44, height: 44)
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(transaction.displayMerchant)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Text(amountString)
                .font(.system(size: 16, weight: .semibold).monospacedDigit())
                .foregroundStyle(transaction.direction == .in ? Color.green : Color.primary)
        }
    }

    private var metaRow: some View {
        HStack(spacing: 6) {
            if let category = transaction.category {
                CategoryPill(category: category, compact: true)
            }
            LocationChip(
                label: transaction.locationLabel,
                status: transaction.locationStatus,
                latitude: transaction.locationLat,
                longitude: transaction.locationLng,
                merchantLabel: transaction.displayMerchant,
                compact: true
            )
            Spacer(minLength: 0)
            Text(timeString)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Strings

    private var amountString: String {
        let prefix = transaction.direction == .in ? "+ " : ""
        let value = NSDecimalNumber(decimal: transaction.amountInr).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = (value.truncatingRemainder(dividingBy: 1) == 0) ? 0 : 2
        return "\(prefix)₹\(f.string(from: NSNumber(value: value)) ?? String(value))"
    }

    private var timeString: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM, HH:mm"
        return df.string(from: transaction.occurredAt)
    }
}

#Preview {
    List {
        ForEach(MockData.transactions) { tx in
            TransactionRow(transaction: tx)
        }
    }
    .listStyle(.plain)
}
