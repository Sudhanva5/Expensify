import SwiftUI

/// Transaction row. Cred-inspired, restrained.
///
///   ○  RAJESH KUMAR                                       ₹547.00
///       food  📍 mtr jayanagar  ⓘ                         9 may '26
///
/// Layout:
///   • Avatar (favicon or initials) on the left
///   • Top-left: merchant title (raw payee). Plain text, NOT tappable —
///     we used to make this clickable but it conflated "see details" with
///     "open Maps" and felt overloaded.
///   • Bottom-left: category, then a small location chip if we have a
///     Places-resolved name, then a small ⓘ to open the detail sheet.
///     The chip is tappable and also opens the detail sheet (it's the
///     primary affordance; the ⓘ is redundant but discoverable).
///   • Bottom-right: small tertiary date.
///   • Right edge: amount stacked over date.
///
/// Tapping the chip or the ⓘ presents `TransactionDetailSheet` as a
/// medium-detent bottom sheet with the map preview.
struct TransactionRow: View {
    let transaction: Transaction
    /// Optional contact-overlay (when iOS matched this row's payee to a
    /// device contact). Threaded through to the detail sheet so the
    /// "VPA Name" small line shows the friend's display name.
    var contactName: String? = nil
    /// Optional contact photo data (the friend's DP from the address book).
    /// Replaces the favicon/initials avatar when present.
    var contactImageData: Data? = nil

    @State private var showDetailSheet: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MerchantAvatar(
                merchantName: transaction.displayMerchant,
                size: 44,
                // Favicon resolves from the BANK's underlying signal —
                // raw payee text, VPA — not the renameable display
                // name. Otherwise renaming a row to "Manju Tea Stall"
                // would chase a Manju favicon that doesn't exist,
                // dropping the actually-stable Paytm-QR / brand logo.
                brandKey: transaction.merchantRaw.isEmpty
                    ? transaction.vpa ?? ""
                    : transaction.merchantRaw,
                contactImageData: contactImageData,
                contactName: effectiveContactName,
                // Falls back to the category SF Symbol when there's no
                // brand favicon and no contact photo — more informative
                // than two-letter initials for places like "Vishnu Garden
                // Bar" where we don't have a logo on file.
                categoryFallback: isContactOverride ? nil : transaction.category
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(AppFont.rowTitle)
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                metaLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                AmountText(amount: transaction.amountInr, direction: transaction.direction)
                Text(dateString)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(AppColor.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { showDetailSheet = true }
        .sheet(isPresented: $showDetailSheet) {
            TransactionDetailSheet(
                transaction: transaction,
                contactName: effectiveContactName,
                contactImageData: contactImageData
            )
        }
    }

    /// Category line. The whole row's `.onTapGesture` opens the detail
    /// sheet — no inline "more details" hint chip.
    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(categoryText)
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textSecondary)

            Spacer(minLength: 0)
        }
    }

    /// True when the row is rendering as a contact-overlay P2P.
    /// Two gates — both must hold:
    ///   1. We have a length-valid contact name (≥3 chars), AND
    ///   2. The row's own category is unset OR explicitly the P2P
    ///      category. If the user has retagged this row to Travel /
    ///      Food / etc., the contact identity is no longer the
    ///      meaningful frame for the row — the user's tag wins, the
    ///      title falls back to the merchant text, and the category
    ///      label reads whatever they chose.
    ///
    /// Without (2), retagging a Rapido driver's personal-VPA debit to
    /// Travel would still display the matched contact's name and a
    /// hard-coded "p2p" subtitle.
    private var isContactOverride: Bool {
        guard effectiveContactName != nil else { return false }
        let cat = transaction.category
        return cat == nil || cat == .personalTransfer
    }

    /// Title row: raw payee from the bank. Plain text. Truncate when long.
    /// Priority order:
    ///   1. Explicit `merchantNormalized` override — set by user-driven
    ///      rename or Places resolution. Beats contact match because
    ///      the user (or the Places resolver) specifically asked for
    ///      this name. Without this, renaming "RAJESH KUMAR" to
    ///      "Manju Tea Stall" would get masked the moment ContactsService
    ///      auto-matched a "Rajesh" in the address book.
    ///   2. Contact-name overlay (auto-matched or pinned). Only takes
    ///      effect when there's no explicit normalized name AND the
    ///      contact name is >= 3 chars (Single-letter contacts return
    ///      bad titles).
    ///   3. Bank's `merchantRaw` as the final fallback.
    private var titleText: String {
        // 1. Explicit override
        let normalized = transaction.merchantNormalized
        if !normalized.isEmpty,
           normalized.caseInsensitiveCompare(transaction.merchantRaw) != .orderedSame {
            return normalized
        }
        // 2. Contact-name overlay
        if let cn = effectiveContactName, !cn.isEmpty {
            return cn
        }
        // 3. Bank text
        return transaction.merchantRaw.isEmpty
            ? transaction.displayMerchant
            : transaction.merchantRaw
    }

    /// Contact name to use for the overlay, after applying the
    /// minimum-length guard. nil means "treat this row as if there was no
    /// contact match" — title falls back to merchantRaw, category stays
    /// at whatever the backend decided.
    private var effectiveContactName: String? {
        guard let cn = contactName?.trimmingCharacters(in: .whitespacesAndNewlines),
              cn.count >= 3 else {
            return nil
        }
        return cn
    }

    private var categoryText: String {
        if isContactOverride {
            // Contact-matched rows are always personal transfers — override
            // whatever the backend's tier chain decided.
            return Category.personalTransfer.shortName.lowercased()
        }
        return transaction.category?.shortName.lowercased() ?? "uncategorized"
    }

    /// Compact date+time — "11th jul | 11:30 am". Drops the year (the
    /// detail sheet has the full timestamp); adds the time so the user
    /// can disambiguate two same-day spends at a glance. Ordinal day
    /// ("11th", "1st", "2nd") matches the Cred-style cadence.
    private var dateString: String {
        let date = transaction.occurredAt
        let ordinal = NumberFormatter()
        ordinal.numberStyle = .ordinal
        let day = Calendar.current.component(.day, from: date)
        let dayStr = ordinal.string(from: NSNumber(value: day)) ?? "\(day)"

        let monthDf = DateFormatter()
        monthDf.dateFormat = "MMM"
        let month = monthDf.string(from: date).lowercased()

        let timeDf = DateFormatter()
        timeDf.dateFormat = "h:mm a"
        let time = timeDf.string(from: date).lowercased()

        return "\(dayStr) \(month) | \(time)"
    }
}

#Preview {
    List {
        ForEach(MockData.transactions) { tx in
            TransactionRow(transaction: tx)
                .listRowSeparator(.hidden)
        }
    }
    .listStyle(.plain)
    .background(AppColor.canvas)
}
