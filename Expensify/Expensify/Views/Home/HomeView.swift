import SwiftUI

/// First tab. Welcome, date filter, transaction log fed by the live API.
struct HomeView: View {
    @Binding var showSettings: Bool
    @Environment(TransactionStore.self) private var store
    @State private var range: DateRange = .defaultRange
    @State private var instrumentFilter: String? = nil  // nil = "All"

    private var dateScoped: [Transaction] {
        store.transactions.filter { range.contains($0.occurredAt) }
    }

    private var availableInstruments: [(instrument: String, count: Int)] {
        var counts: [String: Int] = [:]
        for tx in dateScoped {
            counts[tx.instrument, default: 0] += 1
        }
        return counts
            .map { ($0.key, $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var filtered: [Transaction] {
        dateScoped
            .filter { instrumentFilter == nil || $0.instrument == instrumentFilter }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    /// Time-of-day-aware greeting. "Good morning" / afternoon / evening.
    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 4..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Good night"
        }
    }

    var body: some View {
        NavigationStack {
            list
                .listStyle(.plain)
                .refreshable { await store.refresh() }
                .task {
                    if store.transactions.isEmpty { await store.refresh() }
                }
                .navigationTitle("Expensify")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AvatarButton(initials: "SA") { showSettings = true }
                    }
                }
                .connectivityBanner(store: store)
        }
    }

    private var list: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(greeting)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("Here's what your money's been up to.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 12, trailing: 20))
            }

            Section {
                HStack {
                    DateRangeFilter(range: $range)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 6, trailing: 20))
            }

            if availableInstruments.count > 1 {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            InstrumentPill(
                                label: "All",
                                count: dateScoped.count,
                                isSelected: instrumentFilter == nil
                            ) {
                                instrumentFilter = nil
                            }
                            ForEach(availableInstruments, id: \.instrument) { entry in
                                InstrumentPill(
                                    label: InstrumentLabel.display(for: entry.instrument),
                                    count: entry.count,
                                    isSelected: instrumentFilter == entry.instrument
                                ) {
                                    instrumentFilter = entry.instrument
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }

            if store.isLoading && store.transactions.isEmpty {
                Section {
                    LoadingRowView()
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else if filtered.isEmpty {
                Section {
                    EmptyRowsView(hasAnyTransactions: !store.transactions.isEmpty)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section("Transactions") {
                    ForEach(filtered) { tx in
                        TransactionRow(transaction: tx)
                    }
                }
            }
        }
    }
}

private struct EmptyRowsView: View {
    let hasAnyTransactions: Bool
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(hasAnyTransactions ? "No transactions in this range" : "No transactions yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(hasAnyTransactions
                 ? "Try a wider window from the date filter."
                 : "Spend some money — it'll show up here once an HDFC alert lands in your inbox.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

private struct LoadingRowView: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading transactions…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

#Preview {
    @Previewable @State var s = false
    return HomeView(showSettings: $s)
        .environment(TransactionStore())
}
