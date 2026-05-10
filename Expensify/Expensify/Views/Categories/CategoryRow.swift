import SwiftUI

/// Row in the Categories tab — icon, label, total spent, and a fill bar.
struct CategoryRow: View {
    let category: Category
    let totalSpent: Decimal
    let percentageOfTotal: Double  // 0.0–1.0

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: category.symbolName)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(category.tint)
                    .background(category.tint.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text(category.shortName)
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(amountString)
                    .font(.subheadline.weight(.semibold))

                Text(percentString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(category.tint)
                        .frame(width: max(8, proxy.size.width * percentageOfTotal))
                }
            }
            .frame(height: 6)
        }
        .padding(.vertical, 4)
    }

    private var amountString: String {
        let value = NSDecimalNumber(decimal: totalSpent).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "₹\(f.string(from: NSNumber(value: value)) ?? String(value))"
    }

    private var percentString: String {
        "\(Int((percentageOfTotal * 100).rounded()))%"
    }
}

#Preview {
    List {
        CategoryRow(category: .food, totalSpent: 4250, percentageOfTotal: 0.69)
        CategoryRow(category: .travel, totalSpent: 1200, percentageOfTotal: 0.20)
        CategoryRow(category: .personalTransfer, totalSpent: 500, percentageOfTotal: 0.08)
        CategoryRow(category: .subscriptions, totalSpent: 192, percentageOfTotal: 0.03)
    }
    .listStyle(.plain)
}
