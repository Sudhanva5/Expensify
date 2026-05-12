import SwiftUI

/// Per-category row in the Categories tab. Two display modes:
///
///   - Budgeted: "₹X / ₹Y" with a budget-aware bar fill. The bar caps at 100%
///     of the budget; if spend goes over, the *trailing* percentage label
///     turns red ("113%") so the overage is unmistakable.
///   - Unbudgeted: falls back to the old behavior — spend in primary, share
///     of total spend as a hair of tertiary text on the trailing edge.
struct CategoryRow: View {
    let category: Category
    let totalSpent: Decimal
    /// Share of total spend in the visible range, 0.0–1.0. Used when there
    /// is no budget set for this category.
    let percentageOfTotal: Double
    /// Monthly limit in rupees, if a budget exists for this category.
    let budgetLimit: Decimal?

    private var hasBudget: Bool {
        guard let lim = budgetLimit else { return false }
        return lim > 0
    }

    /// 0.0–1.0+ (uncapped). When this is greater than 1.0 we visually cap the
    /// bar but show the real number in the percentage label so the overage
    /// is obvious.
    private var budgetRatio: Double {
        guard let lim = budgetLimit, lim > 0 else { return 0 }
        let spent = NSDecimalNumber(decimal: totalSpent).doubleValue
        let cap = NSDecimalNumber(decimal: lim).doubleValue
        return spent / cap
    }

    private var isOverBudget: Bool { budgetRatio > 1.0 }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: category.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(AppColor.avatarFill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.shortName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(AppColor.textPrimary)

                    if hasBudget, let lim = budgetLimit {
                        Text("of \(rupees(lim))")
                            .font(.system(size: 11, weight: .regular).monospacedDigit())
                            .foregroundStyle(AppColor.textTertiary)
                    }
                }

                Spacer()

                AmountText(amount: totalSpent, direction: .out)

                trailingLabel
                    .frame(width: 40, alignment: .trailing)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColor.hairline.opacity(0.7))
                    Capsule()
                        .fill(fillColor)
                        .frame(width: max(6, proxy.size.width * fillRatio))
                }
            }
            .frame(height: 3)
            .padding(.leading, 40)
        }
        .padding(.vertical, 4)
    }

    /// Width of the fill, 0.0–1.0. Budget bars cap at 1.0 so the overage is
    /// communicated by the *color* (red) and the *label* (113%), not by the
    /// bar overflowing visually.
    private var fillRatio: Double {
        if hasBudget {
            return min(1.0, max(0, budgetRatio))
        }
        return min(1.0, max(0, percentageOfTotal))
    }

    private var fillColor: Color {
        if hasBudget && isOverBudget {
            return Color.red.opacity(0.8)
        }
        return AppColor.textPrimary
    }

    @ViewBuilder
    private var trailingLabel: some View {
        if hasBudget {
            Text("\(Int((budgetRatio * 100).rounded()))%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(isOverBudget ? .red : AppColor.textTertiary)
        } else {
            Text("\(Int((percentageOfTotal * 100).rounded()))%")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    private func rupees(_ amount: Decimal) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "₹\(f.string(from: NSNumber(value: value)) ?? String(Int(value)))"
    }
}

#Preview {
    List {
        CategoryRow(category: .food, totalSpent: 4250, percentageOfTotal: 0.69, budgetLimit: 6000)
            .listRowSeparator(.hidden)
        CategoryRow(category: .subscriptions, totalSpent: 2300, percentageOfTotal: 0.33, budgetLimit: 800)
            .listRowSeparator(.hidden)
        CategoryRow(category: .travel, totalSpent: 1200, percentageOfTotal: 0.20, budgetLimit: nil)
            .listRowSeparator(.hidden)
        CategoryRow(category: .personalTransfer, totalSpent: 500, percentageOfTotal: 0.08, budgetLimit: nil)
            .listRowSeparator(.hidden)
    }
    .listStyle(.plain)
    .background(AppColor.canvas)
}
