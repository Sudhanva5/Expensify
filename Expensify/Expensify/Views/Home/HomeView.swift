import SwiftUI
import Combine

/// Home tab — Cred-style restrained list.
///
/// Layout (top to bottom):
///   • Lowercase page title + greeting
///   • Filter pills (sort / date scope)
///   • Month section label
///   • Transaction rows (no dividers)
///   • Floating instrument dock at the bottom
struct HomeView: View {
    @Binding var showSettings: Bool
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService
    @State private var range: DateRange = .defaultRange
    @State private var instrumentFilter: String? = nil
    /// When non-nil, the category-picker sheet is presented for this row.
    /// Held at the parent so a swipe action across multiple rows doesn't
    /// conflict with per-row sheet state.
    @State private var editingTagFor: Transaction? = nil

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

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                AppColor.canvas.ignoresSafeArea()

                content
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(AppColor.canvas)
                    .refreshable { await store.refresh() }
                    .task {
                        if store.transactions.isEmpty { await store.refresh() }
                    }
                    .connectivityBanner(store: store)

                if availableInstruments.count > 1 {
                    InstrumentDock(
                        instruments: availableInstruments,
                        selected: $instrumentFilter
                    )
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    AvatarButton(initials: CurrentUser.initials) { showSettings = true }
                }
            }
            .sheet(item: $editingTagFor) { tx in
                CategoryPickerSheet(transaction: tx)
                    .environment(store)
            }
        }
    }

    private var content: some View {
        List {
            // Title block
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("transactions")
                        .font(AppFont.pageTitle)
                        .foregroundStyle(AppColor.textPrimary)
                    Text(greeting)
                        .font(AppFont.rowSubtitle)
                        .foregroundStyle(AppColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 6, trailing: 20))
            }

            // Date filter
            Section {
                HStack {
                    DateRangeFilter(range: $range)
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 20))
            }

            // States
            if store.isLoading && store.transactions.isEmpty {
                Section {
                    LoadingDiagnostic(store: store)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else if filtered.isEmpty {
                Section {
                    EmptyHomeState(hasAnyTransactions: !store.transactions.isEmpty)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else {
                // Group filtered transactions by month for the section label
                ForEach(monthSections(), id: \.label) { section in
                    Section {
                        ForEach(section.transactions) { tx in
                            rowFor(tx)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button {
                                        // Small async hop so SwiftUI can
                                        // finish dismissing the swipe-action
                                        // tray before we present the sheet.
                                        // Without this, .sheet(item:) often
                                        // silently no-ops on iOS 17.
                                        Task { @MainActor in
                                            try? await Task.sleep(nanoseconds: 100_000_000)
                                            editingTagFor = tx
                                        }
                                    } label: {
                                        Label("Edit Tag", systemImage: "tag")
                                    }
                                    .tint(AppColor.tap)
                                }
                        }
                    } header: {
                        Text(section.label)
                            .font(AppFont.sectionLabel)
                            .foregroundStyle(AppColor.textTertiary)
                            .padding(.top, 8)
                            .padding(.bottom, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .listRowInsets(EdgeInsets())
                    }
                }

                // Bottom padding so the instrument dock doesn't overlap the
                // last row.
                Section {
                    Color.clear
                        .frame(height: 80)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
    }

    /// Build a row with contact overlay (name + DP) when the transaction's
    /// payee matches someone in the address book.
    @ViewBuilder
    private func rowFor(_ tx: Transaction) -> some View {
        let contact = contactsService.match(for: tx)
        TransactionRow(
            transaction: tx,
            contactName: contact?.displayName,
            contactImageData: contact.flatMap { contactsService.imageData(for: $0) }
        )
    }

    private struct MonthSection: Identifiable {
        let label: String
        let transactions: [Transaction]
        var id: String { label }
    }

    private func monthSections() -> [MonthSection] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { tx -> String in
            let comps = cal.dateComponents([.year, .month], from: tx.occurredAt)
            let date = cal.date(from: comps) ?? tx.occurredAt
            let df = DateFormatter()
            df.dateFormat = "MMMM yyyy"
            return df.string(from: date).uppercased()
        }
        return groups
            .map { MonthSection(label: $0.key, transactions: $0.value) }
            .sorted { lhs, rhs in
                guard let l = lhs.transactions.first?.occurredAt,
                      let r = rhs.transactions.first?.occurredAt else { return false }
                return l > r
            }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 4..<12: return "good morning. here's where your money went."
        case 12..<17: return "good afternoon. here's where your money went."
        case 17..<22: return "good evening. here's where your money went."
        default: return "late night. here's where your money went."
        }
    }
}

/// Shown while the very first transactions fetch is in flight (no data
/// yet). Initially just a spinner; after ~5 seconds it expands to show
/// the host being queried + elapsed time, so the user can verify (a)
/// they're on the rebuilt app pointing at the new custom domain and
/// (b) where the request is stuck without opening Xcode console.
private struct LoadingDiagnostic: View {
    let store: TransactionStore
    @State private var now: Date = Date()
    /// Tick every 0.5s so elapsedSeconds re-renders the diagnostic line.
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var elapsedSeconds: Int {
        guard let started = store.refreshStartedAt else { return 0 }
        return Int(now.timeIntervalSince(started))
    }

    private var showDiagnostic: Bool {
        elapsedSeconds >= 5
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("loading transactions…")
                    .font(AppFont.rowSubtitle)
                    .foregroundStyle(AppColor.textSecondary)
            }

            if showDiagnostic {
                VStack(spacing: 4) {
                    Text("host: \(store.baseHost)")
                        .font(AppFont.caption.monospaced())
                        .foregroundStyle(AppColor.textTertiary)
                    Text("elapsed: \(elapsedSeconds)s")
                        .font(AppFont.caption.monospaced())
                        .foregroundStyle(AppColor.textTertiary)
                    if elapsedSeconds >= 15 {
                        Text("(taking longer than usual)")
                            .font(AppFont.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .onReceive(tick) { _ in now = Date() }
    }
}

private struct EmptyHomeState: View {
    let hasAnyTransactions: Bool
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(AppColor.textTertiary)
            Text(hasAnyTransactions ? "nothing in this range" : "no transactions yet")
                .font(AppFont.rowSubtitle)
                .foregroundStyle(AppColor.textSecondary)
            Text(
                hasAnyTransactions
                    ? "widen the date filter to see more."
                    : "spend something — it'll land here once HDFC emails it."
            )
            .font(AppFont.caption)
            .foregroundStyle(AppColor.textTertiary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

#Preview {
    @Previewable @State var s = false
    return HomeView(showSettings: $s)
        .environment(TransactionStore())
        .environment(ContactsService())
}
