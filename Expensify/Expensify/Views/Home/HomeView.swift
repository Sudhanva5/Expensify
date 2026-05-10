import SwiftUI

/// First tab. Welcome, date filter, transaction log fed by the live API.
struct HomeView: View {
    @Binding var showSettings: Bool
    @Environment(TransactionStore.self) private var store
    @State private var range: DateRange = .defaultRange

    private var filtered: [Transaction] {
        store.transactions
            .filter { range.contains($0.occurredAt) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hi, welcome to Expensify")
                            .font(.title2.weight(.semibold))
                        Text("Track every rupee that leaves your account.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 16, leading: 16, bottom: 8, trailing: 16))
                }

                Section {
                    HStack {
                        DateRangeFilter(range: $range)
                        Spacer()
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                }

                if let err = store.loadError {
                    Section {
                        ErrorRowView(message: err) {
                            Task { await store.refresh() }
                        }
                        .listRowSeparator(.hidden)
                    }
                } else if store.isLoading && store.transactions.isEmpty {
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

private struct ErrorRowView: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn't load transactions")
                .font(.subheadline.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry", action: retry)
                .buttonStyle(.bordered)
                .padding(.top, 4)
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
