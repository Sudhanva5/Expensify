import SwiftUI
import Charts

/// Analytics tab (formerly "Categories"). Headline spend stats + a
/// category-wise budget-vs-actual comparison, scoped by a floating filter.
///
/// Layout:
///   • Header — "Analytics" + avatar (same treatment as Home)
///   • Four stat cards — total, daily average, top category, biggest expense
///   • Budget-vs-actual bar chart, per category
///   • Floating filter button (always present) to scope the data
struct AnalyticsView: View {
    @Binding var showSettings: Bool
    @Environment(TransactionStore.self) private var store
    @Environment(BudgetStore.self) private var budgetStore
    @Environment(ProfilePhotoStore.self) private var profilePhotoStore

    @State private var range: DateRange = .defaultRange
    /// Category whose bar the user tapped — drives the value callout.
    @State private var selectedCategory: String?

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    /// Over-budget red (within-budget uses `AppColor.inflow` green).
    private let overColor = Color(red: 0.88, green: 0.28, blue: 0.25)
    private let budgetBarColor = AppColor.textTertiary

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    statGrid
                    budgetVsActualCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 96)   // clear the floating filter
            }
            .background(AppColor.canvas)
            .navigationBarHidden(true)
            // Floating filter — always present; scopes every stat + chart.
            .overlay(alignment: .bottomTrailing) {
                DateRangeFilter(range: $range, appearance: .fab)
                    .padding(.trailing, 18)
                    .padding(.bottom, 18)
            }
            .refreshable {
                await store.refresh()
                await budgetStore.refresh()
            }
            .task {
                if store.transactions.isEmpty { await store.refresh() }
            }
            .connectivityBanner(store: store)
        }
    }

    // MARK: Header (mirrors Home)

    private var header: some View {
        HStack(alignment: .center) {
            Text("Analytics")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            AvatarButton(initials: CurrentUser.initials,
                         image: profilePhotoStore.image) { showSettings = true }
        }
    }

    // MARK: Stat grid

    private var statGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            statCard(label: "Total Spends",
                     value: formatRupees(totalSpend),
                     sub: "so far")
            statCard(label: "Daily Average",
                     value: formatRupees(dailyAverage),
                     sub: "per day")
            statCard(label: "Biggest Category",
                     value: topCategory?.category.shortName ?? "—",
                     sub: topCategory.map { formatRupees($0.total) } ?? "no spend")
            statCard(label: "Biggest Expense",
                     value: biggestExpense.map { formatRupees($0.amountInr) } ?? "—",
                     sub: biggestExpense?.displayMerchant ?? "no spend")
        }
    }

    private func statCard(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColor.textSecondary)
            Text(value)
                .font(.system(size: 24, weight: .bold).monospacedDigit())
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(sub)
                .font(.system(size: 12))
                .foregroundStyle(AppColor.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: Budget vs actual — per category

    private var budgetVsActualCard: some View {
        let data = comparisons
        return VStack(alignment: .leading, spacing: 10) {
            Text("Budget vs Actual")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(AppColor.textPrimary)
            Text("By category · tap a bar for the numbers")
                .font(.system(size: 12))
                .foregroundStyle(AppColor.textTertiary)

            // Value callout for the tapped category (green within / red over).
            if let sel = selectedCategory,
               let c = data.first(where: { $0.name == sel }) {
                calloutView(c)
            }

            if data.isEmpty {
                Text("No spend or budgets in this period")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                Chart {
                    ForEach(data) { c in
                        // Actual — green within budget, red over budget.
                        BarMark(
                            x: .value("Amount", c.actual),
                            y: .value("Category", c.name)
                        )
                        .foregroundStyle(c.over ? overColor : AppColor.inflow)
                        .position(by: .value("Kind", "Actual"))
                        .cornerRadius(4)
                        // Budget — neutral reference bar.
                        BarMark(
                            x: .value("Amount", c.budget),
                            y: .value("Category", c.name)
                        )
                        .foregroundStyle(budgetBarColor)
                        .position(by: .value("Kind", "Budget"))
                        .cornerRadius(4)
                    }
                }
                .chartYSelection(value: $selectedCategory)
                .frame(height: CGFloat(categoryCount * 56 + 40))
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(AppColor.hairline)
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(shortAmount(v))
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppColor.textTertiary)
                            }
                        }
                    }
                }
                .padding(.top, 4)

                legend
            }
        }
        .padding(16)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    /// Numbers for the tapped category: actual vs budget + over/within tag.
    private func calloutView(_ c: CategoryComparison) -> some View {
        HStack(spacing: 10) {
            Text(c.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            Text("\(formatRupees(Decimal(c.actual))) / \(formatRupees(Decimal(c.budget)))")
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppColor.textPrimary)
            Text(c.over ? "Over" : "Within")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(c.over ? overColor : AppColor.inflow)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background((c.over ? overColor : AppColor.inflow).opacity(0.12), in: Capsule())
        }
        .padding(.vertical, 6)
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendSwatch(AppColor.inflow, "Within budget")
            legendSwatch(overColor, "Over budget")
            legendSwatch(budgetBarColor, "Budget")
        }
        .padding(.top, 2)
    }

    private func legendSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AppColor.textTertiary)
        }
    }

    // MARK: - Data

    private var calendar: Calendar { Calendar.current }

    private var rangeOutflows: [Transaction] {
        store.transactions.filter { $0.direction == .out && range.contains($0.occurredAt) }
    }

    private var totalSpend: Decimal {
        rangeOutflows.reduce(Decimal(0)) { $0 + $1.amountInr }
    }

    private var dailyAverage: Decimal {
        totalSpend / Decimal(max(rangeDayCount, 1))
    }

    private var topCategory: (category: Category, total: Decimal)? {
        categoryActuals
            .map { (category: $0.key, total: $0.value) }
            .max { $0.total < $1.total }
    }

    private var biggestExpense: Transaction? {
        rangeOutflows.max { $0.amountInr < $1.amountInr }
    }

    private var categoryActuals: [Category: Decimal] {
        var dict: [Category: Decimal] = [:]
        for tx in rangeOutflows {
            guard let c = tx.category else { continue }
            dict[c, default: 0] += tx.amountInr
        }
        return dict
    }

    /// Per-category actual-vs-budget comparison — only categories with
    /// spend or a budget in the period.
    private var comparisons: [CategoryComparison] {
        let actuals = categoryActuals
        return Category.allCases.compactMap { cat -> CategoryComparison? in
            let actual = NSDecimalNumber(decimal: actuals[cat] ?? 0).doubleValue
            let budget = NSDecimalNumber(decimal: budgetStore.budget(for: cat).monthlyLimitInr ?? 0).doubleValue
            guard actual > 0 || budget > 0 else { return nil }
            return CategoryComparison(name: cat.shortName, actual: actual, budget: budget)
        }
    }

    private var categoryCount: Int { max(comparisons.count, 1) }

    /// Number of calendar days the active range spans (for the daily avg).
    private var rangeDayCount: Int {
        let now = Date()
        switch range {
        case .day:
            return 1
        case .month(let year, let month):
            guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else { return 30 }
            if calendar.isDate(monthStart, equalTo: now, toGranularity: .month) {
                return calendar.component(.day, from: now)
            }
            return calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        case .custom(let start, let end):
            let days = calendar.dateComponents([.day],
                                               from: calendar.startOfDay(for: start),
                                               to: calendar.startOfDay(for: end)).day ?? 0
            return max(days + 1, 1)
        case .all:
            guard let first = rangeOutflows.map(\.occurredAt).min() else { return 1 }
            let days = calendar.dateComponents([.day],
                                               from: calendar.startOfDay(for: first),
                                               to: now).day ?? 0
            return max(days + 1, 1)
        }
    }

    // MARK: - Formatting

    private func formatRupees(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = 0
        return "₹" + (f.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)")
    }
    private func shortAmount(_ v: Double) -> String {
        if v >= 1000 { return "₹\(String(format: "%.0f", v / 1000))k" }
        return "₹\(Int(v))"
    }
}

// MARK: - Models

private struct CategoryComparison: Identifiable {
    let id = UUID()
    let name: String
    let actual: Double
    let budget: Double
    /// Over budget only when a budget is set and actual exceeds it.
    var over: Bool { budget > 0 && actual > budget }
}

#Preview {
    @Previewable @State var s = false
    return AnalyticsView(showSettings: $s)
        .environment(TransactionStore())
        .environment(BudgetStore())
        .environment(ProfilePhotoStore())
}
