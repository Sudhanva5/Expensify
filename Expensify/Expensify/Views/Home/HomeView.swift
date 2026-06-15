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
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(AppColor.canvas)
                .refreshable { await store.refresh() }
                .task {
                    if store.transactions.isEmpty { await store.refresh() }
                }
                .connectivityBanner(store: store)
                // Dock as a bottom safe-area inset, NOT a ZStack overlay.
                //   • Inset means the list naturally ends above the dock —
                //     no list rows hide behind the floating capsule, and
                //     the last row never collides with the chips.
                //   • SwiftUI inserts the inset *above* the tab-bar safe
                //     area, so the dock can't get squashed by tab-bar
                //     height changes, badge animations, or the keyboard.
                //   • Tap routing improves too: chips are no longer
                //     competing for hit-test with scrollable list rows
                //     they sit over.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if availableInstruments.count > 1 {
                        InstrumentDock(
                            instruments: availableInstruments,
                            selected: $instrumentFilter
                        )
                    }
                }
                .background(AppColor.canvas.ignoresSafeArea())
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
                ForEach(monthSections()) { section in
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
                        monthSectionHeader(section)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .padding(.bottom, 8)
                            .listRowInsets(EdgeInsets())
                    }
                }

            }
        }
    }

    /// Build a row with contact overlay (name + DP) when the transaction's
    /// payee matches someone in the address book or the user's Google
    /// contacts. The local CNContactStore is checked first; rows whose
    /// local match has no photo (or whose VPA isn't in the device address
    /// book at all) trigger a one-shot backend lookup against the cached
    /// People API snapshot. The same VPA is requested at most once per
    /// app launch (see ContactsService's `googleNotFoundVpas` set).
    @ViewBuilder
    private func rowFor(_ tx: Transaction) -> some View {
        let displayName = contactsService.bestContactName(for: tx)
        let photo = contactsService.bestPhotoData(for: tx)
        TransactionRow(
            transaction: tx,
            contactName: displayName,
            contactImageData: photo
        )
        .task {
            await contactsService.fetchGooglePhotoIfNeeded(for: tx)
        }
    }

    private struct MonthSection: Identifiable {
        /// Sort key — first-day-of-month timestamp for the bucket.
        let monthStart: Date
        let year: Int          // e.g. 2026
        let monthName: String  // e.g. "June"
        let transactions: [Transaction]
        /// Sum of outflow amounts for the month, in rupees. Inflows are
        /// EXCLUDED — the header is communicating "how much money left
        /// my account this month", not net cash position.
        let totalOutflow: Decimal
        /// String id, not Date, so ForEach's diffing doesn't trip on
        /// any Date-equality subtleties under animated reorder. Format:
        /// "yyyy-MM" — uniquely identifies the month bucket.
        var id: String {
            let cal = Calendar.current
            let comps = cal.dateComponents([.year, .month], from: monthStart)
            return String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
        }
    }

    private func monthSections() -> [MonthSection] {
        let cal = Calendar.current
        // Group by (year, month) keyed on the first-of-month Date — Date
        // is Hashable and sorts naturally, so we don't need a string key.
        let groups = Dictionary(grouping: filtered) { tx -> Date in
            let comps = cal.dateComponents([.year, .month], from: tx.occurredAt)
            return cal.date(from: comps) ?? tx.occurredAt
        }
        let monthDF = DateFormatter()
        monthDF.dateFormat = "MMMM"
        return groups
            .map { (monthStart, txs) -> MonthSection in
                let comps = cal.dateComponents([.year, .month], from: monthStart)
                let outflow = txs
                    .filter { $0.direction == .out }
                    .reduce(Decimal(0)) { $0 + $1.amountInr }
                return MonthSection(
                    monthStart: monthStart,
                    year: comps.year ?? 0,
                    monthName: monthDF.string(from: monthStart),
                    transactions: txs.sorted { $0.occurredAt > $1.occurredAt },
                    totalOutflow: outflow
                )
            }
            .sorted { $0.monthStart > $1.monthStart }
    }

    /// Rich month header. Year reads as a small caption above the month
    /// name; total outflow for that month is right-aligned on the same
    /// baseline as the month name. Reads as:
    ///
    ///   2026
    ///   June                                    ₹9,560
    @ViewBuilder
    private func monthSectionHeader(_ section: MonthSection) -> some View {
        // No bottom hairline rule — iOS pins List section headers at the
        // top during scroll, and a separator line at the bottom of the
        // sticky header reads as a cut-off section instead of a clean
        // header. Spacing below the title carries the visual stop on
        // its own.
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: String(section.year))
                .font(.system(size: 11, weight: .semibold).smallCaps())
                .foregroundStyle(AppColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.monthName.lowercased())
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Spacer(minLength: 8)
                Text(formatRupees(section.totalOutflow))
                    .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
            }
        }
        .padding(.bottom, 4)
    }

    /// "₹9,560" formatter. Uses Indian-grouping (lakh/crore) and drops
    /// trailing zeros — round amounts read cleaner without ".00".
    private func formatRupees(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = 0
        let n = NSDecimalNumber(decimal: amount)
        return "₹" + (f.string(from: n) ?? "\(amount)")
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
