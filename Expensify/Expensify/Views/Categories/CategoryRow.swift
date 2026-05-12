import SwiftUI

/// Per-category row in the Categories tab. Restrained: small monochrome
/// icon, name in primary text, amount in primary, share-of-total as a hair
/// of secondary text. Bar is a thin grey track with a single accent fill.
struct CategoryRow: View {
    let category: Category
    let totalSpent: Decimal
    let percentageOfTotal: Double  // 0.0–1.0

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(AppColor.avatarFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(category.shortName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColor.textPrimary)

                Spacer()

                AmountText(amount: totalSpent, direction: .out)

                Text("\(Int((percentageOfTotal * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(AppColor.textTertiary)
                    .frame(width: 36, alignment: .trailing)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColor.hairline.opacity(0.7))
                    Capsule()
                        .fill(AppColor.textPrimary)
                        .frame(width: max(6, proxy.size.width * percentageOfTotal))
                }
            }
            .frame(height: 3)
            .padding(.leading, 40)  // align bar with category name (after icon)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    List {
        CategoryRow(category: .food, totalSpent: 4250, percentageOfTotal: 0.69)
            .listRowSeparator(.hidden)
        CategoryRow(category: .travel, totalSpent: 1200, percentageOfTotal: 0.20)
            .listRowSeparator(.hidden)
        CategoryRow(category: .personalTransfer, totalSpent: 500, percentageOfTotal: 0.08)
            .listRowSeparator(.hidden)
        CategoryRow(category: .subscriptions, totalSpent: 192, percentageOfTotal: 0.03)
            .listRowSeparator(.hidden)
    }
    .listStyle(.plain)
    .background(AppColor.canvas)
}
