import SwiftUI

/// One row in the Home transaction list and the per-category list.
struct TransactionRow: View {
    let transaction: Transaction

    var body: some View {
        HStack(spacing: 12) {
            // Category icon chip
            ZStack {
                Circle()
                    .fill((transaction.category?.tint ?? .gray).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: transaction.category?.symbolName ?? "questionmark")
                    .foregroundStyle(transaction.category?.tint ?? .secondary)
                    .font(.system(size: 16, weight: .medium))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(transaction.displayMerchant)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if transaction.locationStatus != .notApplicable {
                    LocationChip(
                        label: transaction.locationLabel,
                        status: transaction.locationStatus
                    )
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(amountString)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(transaction.direction == .in ? .green : .primary)
                if transaction.needsReview {
                    Text("Review")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var amountString: String {
        let prefix = transaction.direction == .in ? "+ " : ""
        let value = NSDecimalNumber(decimal: transaction.amountInr).doubleValue
        return "\(prefix)₹\(formatted(value))"
    }

    private var subtitle: String {
        let cat = transaction.category?.shortName ?? "Uncategorized"
        let df = DateFormatter()
        df.dateFormat = "d MMM, HH:mm"
        return "\(cat) · \(df.string(from: transaction.occurredAt))"
    }

    private func formatted(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = (value.truncatingRemainder(dividingBy: 1) == 0) ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? String(value)
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
