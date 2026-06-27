import SwiftUI

/// Drill-in detail for a spend tile (a category, or the combined
/// credit-cards view). Layout, top to bottom:
///   • Back chevron
///   • Central icon + category name
///   • Period header — year over month (left, like Home) and
///     "<name> spends" + total (right)
///   • List of every transaction in this category for the period
///
/// Holds a binding to the shared `range`, so the floating filter button
/// re-scopes the detail (and Home) live.
struct SpendDetailView: View {
    let selection: SpendSelection
    @Binding var range: DateRange

    @Environment(\.dismiss) private var dismiss
    @Environment(TransactionStore.self) private var store
    @Environment(ContactsService.self) private var contactsService

    /// For the Credit Cards view: which card instrument is selected
    /// (nil = all cards).
    @State private var selectedCard: String?

    // MARK: Identity (derived from the selection)

    private var title: String {
        switch selection {
        case .creditCards: return "Credit Cards"
        case .category(let c): return c.shortName
        }
    }
    private var imageName: String? {
        switch selection {
        case .creditCards: return "CatCreditCards"
        case .category(let c): return c.spendImageName
        }
    }
    private var symbol: String? {
        switch selection {
        case .creditCards: return "creditcard.fill"
        case .category(let c): return c.symbolName
        }
    }

    // MARK: Data (recomputed live as `range` changes)

    private var transactions: [Transaction] {
        let scoped = store.transactions.filter {
            range.contains($0.occurredAt) && $0.direction == .out
        }
        switch selection {
        case .creditCards:
            let cards = scoped.filter { $0.instrument.hasPrefix("card_") }
            if let selectedCard { return cards.filter { $0.instrument == selectedCard } }
            return cards
        case .category(let c):
            return scoped.filter { $0.category == c }
        }
    }

    /// Distinct credit-card instruments across all spend (range-independent
    /// so the segments stay stable as the filter changes).
    private var cardInstruments: [String] {
        Array(Set(store.transactions
            .filter { $0.direction == .out && $0.instrument.hasPrefix("card_") }
            .map(\.instrument)))
            .sorted()
    }
    private var total: Decimal {
        transactions.reduce(Decimal(0)) { $0 + $1.amountInr }
    }
    private var sorted: [Transaction] {
        transactions.sorted { $0.occurredAt > $1.occurredAt }
    }

    // MARK: Period header strings (mirror Home: "2026" over "June")

    private var periodTop: String {
        if case .month(let year, _) = range { return String(year) }
        return ""
    }
    private var periodMain: String {
        if case .month(_, let month) = range {
            let df = DateFormatter()
            df.dateFormat = "MMMM"
            let comps = DateComponents(year: 2026, month: month, day: 1)
            return df.string(from: Calendar.current.date(from: comps) ?? Date())
        }
        let l = range.label
        return l.prefix(1).uppercased() + l.dropFirst()
    }

    var body: some View {
        List {
            heroSection
            headerSection
            if isCreditCards, cardInstruments.count > 1 {
                cardPickerSection
            }
            transactionsSection
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColor.canvas)
        .navigationBarHidden(true)
        .safeAreaInset(edge: .top, spacing: 0) { topBar }
        .overlay(alignment: .bottomTrailing) {
            DateRangeFilter(range: $range, appearance: .fab)
                .padding(.trailing, 18)
                .padding(.bottom, 18)
        }
    }

    // MARK: Back bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                    .frame(width: 40, height: 40)
                    .glassControl(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(AppColor.canvas)
    }

    // MARK: Hero — central icon + name (tight gap between them)

    private var heroSection: some View {
        Section {
            VStack(spacing: 4) {
                artwork
                    .frame(width: 96, height: 96)
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppColor.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 36)   // big gap down to the month header
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
        }
        .listSectionSpacing(.compact)
    }

    @ViewBuilder
    private var artwork: some View {
        if let imageName {
            Image(imageName)
                .resizable()
                .scaledToFit()
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(AppColor.textSecondary)
        }
    }

    // MARK: Period header — year/month (left), "<name> spends" + total (right)

    private var headerSection: some View {
        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if !periodTop.isEmpty {
                        Text(verbatim: periodTop)
                            .font(.system(size: 12, weight: .semibold).smallCaps())
                            .foregroundStyle(AppColor.textTertiary)
                    }
                    Text(periodMain)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(AppColor.textPrimary)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Spends")
                        .font(.system(size: 12, weight: .semibold).smallCaps())
                        .foregroundStyle(AppColor.textTertiary)
                    Text(formatRupees(total))
                        .font(.system(size: 22, weight: .semibold).monospacedDigit())
                        .foregroundStyle(AppColor.textPrimary)
                }
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 28, trailing: 20))
        }
        .listSectionSpacing(0)
    }

    // MARK: Card segmenter (Credit Cards only)

    private var isCreditCards: Bool {
        if case .creditCards = selection { return true }
        return false
    }

    private var cardPickerSection: some View {
        Section {
            Picker("Card", selection: $selectedCard) {
                Text("All").tag(String?.none)
                ForEach(cardInstruments, id: \.self) { inst in
                    Text(CreditCardCatalog.name(forInstrument: inst))
                        .tag(String?.some(inst))
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 14, trailing: 20))
        }
        .listSectionSpacing(0)
    }

    // MARK: Transactions

    @ViewBuilder
    private var transactionsSection: some View {
        Section {
            if sorted.isEmpty {
                Text("No transactions in this period")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(sorted) { tx in
                    TransactionRow(
                        transaction: tx,
                        contactName: contactsService.bestContactName(for: tx),
                        contactImageData: contactsService.bestPhotoData(for: tx)
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                    .task { await contactsService.fetchGooglePhotoIfNeeded(for: tx) }
                }
            }
        }
        // Bottom spacer so the last row clears the floating filter button.
        Section {
            Color.clear
                .frame(height: 72)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    /// "₹4,234" — Indian grouping, no decimals.
    private func formatRupees(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_IN")
        f.maximumFractionDigits = 0
        return "₹" + (f.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)")
    }
}

/// Friendly names for credit-card instruments in the card segmenter.
/// Map each card by its last-4 (e.g. "3328": "Swiggy HDFC"). Unmapped
/// cards fall back to "••<last4>".
enum CreditCardCatalog {
    /// Fill in your cards by last-4, e.g. ["3328": "Swiggy HDFC",
    /// "2668": "Regalia", "1452": "RuPay"]. Unmapped → "••<last4>".
    static let names: [String: String] = [:]
    static func name(forInstrument instrument: String) -> String {
        let last4 = instrument.split(separator: "_").last.map(String.init) ?? instrument
        return names[last4] ?? "••\(last4)"
    }
}
