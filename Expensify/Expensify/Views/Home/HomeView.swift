import SwiftUI

/// First tab. Welcome, date filter, transaction log.
struct HomeView: View {
    @Binding var showSettings: Bool
    @State private var range: DateRange = .defaultRange

    private var filtered: [Transaction] {
        MockData.transactions
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

                if filtered.isEmpty {
                    Section {
                        EmptyRowsView()
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
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No transactions in this range")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Try a wider window from the date filter.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }
}

#Preview {
    @Previewable @State var s = false
    return HomeView(showSettings: $s)
}
