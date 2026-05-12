import SwiftUI

/// Categories tab — spending breakdown by category for the chosen range.
struct CategoriesView: View {
    @Binding var showSettings: Bool
    @Environment(TransactionStore.self) private var store
    @State private var range: DateRange = .defaultRange

    private var totalsByCategory: [(category: Category, total: Decimal)] {
        let outflows = store.transactions.filter {
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
            ZStack {
                AppColor.canvas.ignoresSafeArea()

                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("categories")
                                .font(AppFont.pageTitle)
                                .foregroundStyle(AppColor.textPrimary)
                            Text("how the money split")
                                .font(AppFont.rowSubtitle)
                                .foregroundStyle(AppColor.textSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
                    }

                    Section {
                        HStack {
                            DateRangeFilter(range: $range)
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 16, trailing: 20))
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("total spent")
                                .font(AppFont.sectionLabel)
                                .foregroundStyle(AppColor.textTertiary)
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(totalIntegerString)
                                    .font(AppFont.bigNumber)
                                    .foregroundStyle(AppColor.textPrimary)
                                Text(totalDecimalString)
                                    .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(AppColor.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 16, trailing: 20))
                    }

                    if totalsByCategory.isEmpty {
                        Section {
                            EmptyCategoriesState()
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
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
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        } header: {
                            Text("by category")
                                .font(AppFont.sectionLabel)
                                .foregroundStyle(AppColor.textTertiary)
                                .padding(.horizontal, 20)
                                .padding(.top, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppColor.canvas)
                .refreshable { await store.refresh() }
                .task {
                    if store.transactions.isEmpty { await store.refresh() }
                }
                .connectivityBanner(store: store)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton(initials: CurrentUser.initials) { showSettings = true }
                }
            }
        }
    }

    private var totalIntegerString: String {
        let value = NSDecimalNumber(decimal: grandTotal).doubleValue
        let intValue = Int(value)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return "₹\(f.string(from: NSNumber(value: intValue)) ?? "\(intValue)")"
    }

    private var totalDecimalString: String {
        let value = NSDecimalNumber(decimal: grandTotal).doubleValue
        let cents = Int((value.truncatingRemainder(dividingBy: 1) * 100).rounded())
        return cents == 0 ? "" : String(format: ".%02d", cents)
    }

    private func percentage(of total: Decimal) -> Double {
        guard grandTotal > 0 else { return 0 }
        return NSDecimalNumber(decimal: total).doubleValue
            / NSDecimalNumber(decimal: grandTotal).doubleValue
    }
}

private struct EmptyCategoriesState: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.pie")
                .font(.system(size: 36))
                .foregroundStyle(AppColor.textTertiary)
            Text("nothing to break down")
                .font(AppFont.rowSubtitle)
                .foregroundStyle(AppColor.textSecondary)
            Text("transactions in this range haven't been categorized yet.")
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

struct CategoryDetailView: View {
    let category: Category
    let range: DateRange
    @Environment(TransactionStore.self) private var store

    private var rows: [Transaction] {
        store.transactions
            .filter { $0.category == category && $0.direction == .out && range.contains($0.occurredAt) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        ZStack {
            AppColor.canvas.ignoresSafeArea()
            List(rows) { tx in
                TransactionRow(transaction: tx)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppColor.canvas)
        }
        .navigationTitle(category.shortName.lowercased())
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    @Previewable @State var s = false
    return CategoriesView(showSettings: $s)
        .environment(TransactionStore())
}
