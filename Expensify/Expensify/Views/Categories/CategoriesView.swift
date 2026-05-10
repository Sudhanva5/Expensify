import SwiftUI

/// Second tab. Spending grouped by category for the selected date range.
struct CategoriesView: View {
    @Binding var showSettings: Bool
    @State private var range: DateRange = .defaultRange

    private var totalsByCategory: [(category: Category, total: Decimal)] {
        let outflows = MockData.transactions.filter {
            $0.direction == .out && range.contains($0.occurredAt) && $0.category != nil
        }

        var dict: [Category: Decimal] = [:]
        for tx in outflows {
            guard let cat = tx.category else { continue }
            dict[cat, default: 0] += tx.amountInr
        }
        return dict
            .map { ($0.key, $0.value) }
            .sorted { $0.total > $1.total }
    }

    private var grandTotal: Decimal {
        totalsByCategory.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        DateRangeFilter(range: $range)
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 0, trailing: 16))
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Total spent")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(totalString)
                                .font(.title2.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .listRowSeparator(.hidden)
                }

                if totalsByCategory.isEmpty {
                    EmptyCategoriesView()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    Section("By category") {
                        ForEach(totalsByCategory, id: \.category) { entry in
                            NavigationLink {
                                CategoryDetailView(category: entry.category, range: range)
                            } label: {
                                CategoryRow(
                                    category: entry.category,
                                    totalSpent: entry.total,
                                    percentageOfTotal: percentage(of: entry.total)
                                )
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton(initials: "SA") { showSettings = true }
                }
            }
        }
    }

    private var totalString: String {
        let value = NSDecimalNumber(decimal: grandTotal).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return "₹\(f.string(from: NSNumber(value: value)) ?? String(value))"
    }

    private func percentage(of total: Decimal) -> Double {
        guard grandTotal > 0 else { return 0 }
        return NSDecimalNumber(decimal: total).doubleValue
            / NSDecimalNumber(decimal: grandTotal).doubleValue
    }
}

private struct EmptyCategoriesView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.pie")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Nothing to categorize yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Once you spend money, it'll show up here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

/// Pushed when you tap a category row — shows just transactions in that
/// category for the same date range.
struct CategoryDetailView: View {
    let category: Category
    let range: DateRange

    private var rows: [Transaction] {
        MockData.transactions
            .filter { $0.category == category && $0.direction == .out && range.contains($0.occurredAt) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        List(rows) { tx in
            TransactionRow(transaction: tx)
        }
        .listStyle(.plain)
        .navigationTitle(category.shortName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    @Previewable @State var s = false
    return CategoriesView(showSettings: $s)
}
