import SwiftUI
import Combine

/// Home tab — Cred-style restrained list.
///
/// Layout (top to bottom):
///   • Wallet balance hero (bank-card artwork + balance lettering)
///   • Filter pills (sort / date scope)
///   • Month section label
///   • Transaction rows (no dividers)
///   • Floating instrument dock at the bottom
struct HomeView: View {
    @Binding var showSettings: Bool
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService
    @Environment(ProfilePhotoStore.self) private var profilePhotoStore
    @State private var range: DateRange = .defaultRange
    @State private var instrumentFilter: String? = nil
    /// When non-nil, the category-picker sheet is presented for this row.
    /// Held at the parent so a swipe action across multiple rows doesn't
    /// conflict with per-row sheet state.
    @State private var editingTagFor: Transaction? = nil
    /// Latest known account balance(s). Loaded on appear + on user-tap
    /// of the refresh button. Empty while pending so the card renders
    /// a placeholder instead of "₹0.00" zero-state.
    @State private var accountBalances: [AccountBalance] = []
    @State private var balanceLoading: Bool = false
    /// Spend tile the user drilled into; drives the category-detail push.
    @State private var selectedSpend: SpendSelection? = nil

    private var dateScoped: [Transaction] {
        store.transactions.filter { range.contains($0.occurredAt) }
    }

    /// Combined outflow across all credit-card instruments (`card_*`)
    /// within the active date scope — the headline "Credit Cards" tile.
    /// Replaces the old per-card instrument breakdown.
    private var creditCardTotal: Decimal {
        dateScoped
            .filter { $0.direction == .out && $0.instrument.hasPrefix("card_") }
            .reduce(Decimal(0)) { $0 + $1.amountInr }
    }

    /// Per-category outflow within the active scope — only categories with
    /// bundled art and non-zero spend, sorted high→low.
    private var categorySpends: [(category: Category, total: Decimal)] {
        var totals: [Category: Decimal] = [:]
        for tx in dateScoped where tx.direction == .out {
            guard let c = tx.category, c.spendImageName != nil else { continue }
            totals[c, default: 0] += tx.amountInr
        }
        return totals
            .map { (category: $0.key, total: $0.value) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
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
                .refreshable {
                    await store.refresh()
                    await refreshBalances()
                }
                .task {
                    if store.transactions.isEmpty { await store.refresh() }
                    if accountBalances.isEmpty { await refreshBalances() }
                }
                .connectivityBanner(store: store)
                // Floating filter button — bottom-trailing, above the
                // instrument dock / tab bar. Replaces the inline filter row
                // so the list starts higher. Carries the same Menu + picker
                // sheets as the old pill.
                .overlay(alignment: .bottomTrailing) {
                    DateRangeFilter(range: $range, appearance: .fab)
                        .padding(.trailing, 18)
                        .padding(.bottom, 18)
                }
                .background(AppColor.canvas.ignoresSafeArea())
                // Nav bar hidden — the header (title + avatar) lives in the
                // page body as its own row, so we don't spend a nav-bar's
                // worth of vertical space on chrome.
                .navigationBarHidden(true)
                .sheet(item: $editingTagFor) { tx in
                    CategoryPickerSheet(transaction: tx)
                        .environment(store)
                }
                .navigationDestination(item: $selectedSpend) { selection in
                    detailView(for: selection)
                }
        }
    }

    /// Builds the drill-in detail for a tapped spend tile. The detail owns
    /// a binding to `range`, so its filter button re-scopes both screens.
    private func detailView(for selection: SpendSelection) -> some View {
        SpendDetailView(selection: selection, range: $range)
    }

    private var content: some View {
        List {
            // Header row — title and avatar on one line, in the page body
            // (not the nav bar). Title sits left, avatar pinned right.
            Section {
                HStack(alignment: .center) {
                    Text("Transactions")
                        // Apple HIG large-title scale (34pt bold).
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    AvatarButton(initials: CurrentUser.initials,
                                 image: profilePhotoStore.image) { showSettings = true }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 6, trailing: 16))
            }
            .listSectionSpacing(0)

            // Balance card — the wallet hero leads the page (the old
            // night-sky HeroSection was removed in the UI revamp). Breathing
            // room below so it reads as its own beat before the list.
            Section {
                balanceCard
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 12, leading: 10, bottom: 6, trailing: 10))
            }
            .listSectionSpacing(.compact)

            // (Date filter moved to a floating action button — see the
            // `.fab` DateRangeFilter overlay in the body — to reclaim the row.
            // Spend tiles render inside the first month section, just after
            // its header — see `monthSections()` loop below.)

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
                ForEach(Array(monthSections().enumerated()), id: \.element.id) { index, section in
                    Section {
                        // Spend tiles sit just after the first month header.
                        if index == 0 {
                            CategorySpendRow(creditCardTotal: creditCardTotal,
                                             categories: categorySpends,
                                             onSelect: { selectedSpend = $0 })
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 12, trailing: 0))
                        }
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
                                        Label("Edit", systemImage: "slider.horizontal.3")
                                    }
                                    .tint(AppColor.tap)
                                }
                        }
                    } header: {
                        // Tight above (sits close under the wallet); the gap
                        // BELOW the header to the spend tiles is created by
                        // the tiles' own top inset (first section only).
                        monthSectionHeader(section)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.top, 2)
                            .padding(.bottom, 4)
                            .listRowInsets(EdgeInsets())
                    }
                }

            }
        }
    }

    /// Account-balance card. HDFC badge + bank label, then the balance,
    /// then a small "as of <date>" caption. Refresh icon top-right
    /// re-queries the backend (which returns whatever HDFC's last
    /// "Account update" email said — there's no way to force HDFC to
    /// email a fresh balance on demand).
    /// Account-balance hero — the bank-card wallet illustration with the
    /// live balance written across its front pocket, so the card reads as
    /// a physical wallet showing what's inside. The blue HDFC card is part
    /// of the artwork, so there's no separate bank badge anymore.
    @ViewBuilder
    private var balanceCard: some View {
        let primary = accountBalances.first
        Image("AccountBalanceWallet")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { geo in
                    let w = geo.size.width
                    let h = geo.size.height

                    // Lettering sits on the brown front pocket (lower ⅔ of
                    // the wallet). Ink is FIXED white, not a dynamic token —
                    // the brown artwork doesn't flip in dark mode, so the
                    // text stays white in both. Balance is refreshed by the
                    // page's pull-to-refresh, so there's no inline button.
                    VStack(spacing: 3) {
                        Text("Account Balance")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(walletInk.opacity(0.78))
                        balanceText(primary?.balanceInr)
                            .foregroundStyle(walletInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text(asOfText)
                            .font(.system(size: 10))
                            .foregroundStyle(walletInk.opacity(0.6))
                    }
                    .frame(width: w * 0.82)
                    .position(x: w / 2, y: h * 0.69)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(primary.map { "Account balance ₹\(groupedRupees($0.balanceInr))" }
                                 ?? "Account balance unavailable")
    }

    /// Fixed white ink for lettering on the brown wallet artwork.
    /// Deliberately NOT a dynamic AppColor token — the wallet PNG doesn't
    /// flip in dark mode, so the text stays white in both or it'd vanish
    /// against the brown leather.
    private let walletInk = Color.white

    /// Hero balance lettering — standard SF Pro throughout. The ₹ glyph is
    /// a touch smaller than the digits, which stay monospaced so the number
    /// reads cleanly. Concatenated into one Text so symbol and digits
    /// baseline-align and scale together. "—" while the first balance fetch
    /// is still pending.
    @ViewBuilder
    private func balanceText(_ amount: Decimal?) -> some View {
        if let amount {
            Text(verbatim: "₹")
                .font(.system(size: 38, weight: .bold))
            + Text(verbatim: groupedRupees(amount))
                .font(.system(size: 42, weight: .bold).monospacedDigit())
        } else {
            Text(verbatim: "—")
                .font(.system(size: 42, weight: .bold))
        }
    }

    /// Indian-grouped whole rupees, no symbol ("34,235").
    private func groupedRupees(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = 0
        return f.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private var asOfText: String {
        guard let p = accountBalances.first else {
            return "no balance email parsed yet"
        }
        let df = DateFormatter()
        df.dateFormat = "d MMM ''yy"
        return "as of \(df.string(from: p.asOf).lowercased())"
    }

    private func formatRupees(_ amount: Decimal?) -> String {
        guard let amount else { return "—" }
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.currencySymbol = "₹"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        f.locale = Locale(identifier: "en_IN")
        return f.string(from: NSNumber(value: value)) ?? "₹\(value)"
    }

    private func refreshBalances() async {
        balanceLoading = true
        defer { balanceLoading = false }
        do {
            accountBalances = try await APIClient.shared.fetchAccountBalances()
        } catch {
            // Silent fail — chrome stays put, no banner. iOS already
            // surfaces broader connectivity issues via the existing
            // .connectivityBanner modifier.
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
                .font(.system(size: 12, weight: .semibold).smallCaps())
                .foregroundStyle(AppColor.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.monthName)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(AppColor.textPrimary)
                Spacer(minLength: 8)
                Text(formatRupees(section.totalOutflow))
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
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
        .environment(ProfilePhotoStore())
}
