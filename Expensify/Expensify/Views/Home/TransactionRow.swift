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
                    .font(.system(size: 11))
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .sheet(isPresented: $showDetailSheet) {
            TransactionDetailSheet(
                transaction: transaction,
                contactName: effectiveContactName,
                contactImageData: contactImageData
            )
        }
    }

    /// Category line + (optional) location chip + (optional) ⓘ. Chip is
    /// shown only when we have a Places-resolved name; ⓘ is shown when
    /// either Places resolved this OR we just have coords (e.g. iOS
    /// uploaded location but no Places match) — so the user always has a
    /// way into the detail/map sheet when there's something to see.
    @ViewBuilder
    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(categoryText)
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textSecondary)

            // "more details" chip — opens the bottom sheet with the map +
            // probable-place name. Replaced the inline location chip + the
            // bare ⓘ glyph; a labeled chip is more discoverable than a
            // single icon and clearer about what tapping will do.
            if shouldShowInfo {
                Button(action: { showDetailSheet = true }) {
                    Text("more details")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppColor.tap)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AppColor.tap.opacity(0.08))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show transaction details")
            }

            Spacer(minLength: 0)
        }
    }

    /// True when this row is rendering as a contact-overlay P2P. Used to
    /// suppress the Places chip and override the category label. Uses the
    /// length-guarded contact name so single-letter matches don't trigger
    /// a P2P override on an otherwise-valid merchant row.
    private var isContactOverride: Bool {
        effectiveContactName != nil
    }

    /// Title row: raw payee from the bank. Plain text. Truncate when long.
    /// Uses the matched contact name when present AND long enough to be
    /// useful (>= 3 chars). Single-letter or empty contact names (which
    /// Contacts can return when a contact only has initials saved) are
    /// rejected — falling back to the bank's raw name is more informative
    /// than rendering "I" as a row title.
    private var titleText: String {
        if let cn = effectiveContactName, !cn.isEmpty {
            return cn
        }
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

    /// Show the "more details" chip when the sheet would actually have
    /// something useful in it — either a resolved business name (probable
    /// nearby place) or coordinates for the map preview.
    private var shouldShowInfo: Bool {
        transaction.hasResolvedMerchant || transaction.hasCoordinates
    }

    private var categoryText: String {
        if isContactOverride {
            // Contact-matched rows are always personal transfers — override
            // whatever the backend's tier chain decided.
            return Category.personalTransfer.shortName.lowercased()
        }
        return transaction.category?.shortName.lowercased() ?? "uncategorized"
    }

    /// Compact date — "9 May '26".
    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM ''yy"
        return df.string(from: transaction.occurredAt).lowercased()
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
