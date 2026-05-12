import SwiftUI

/// Transaction row. Cred-inspired, restrained.
///
///   ○  RAJESH KUMAR  ↗  ⓘ                                ₹547.00
///       food                                              9 may '26
///
/// Layout:
///   • Avatar (favicon or initials) on the left
///   • Top: merchant title (tappable when we have coords — opens Maps) +
///     amount on the right. A small `↗` glyph hints that the title is
///     tappable. A tiny `ⓘ` button appears when Places resolved an actual
///     business name (so the user can peek at "what this place really is"
///     without losing the raw VPA payee in the title).
///   • Bottom-left: category, alone. No inline location — the city was
///     adding noise without telling the user anything they couldn't already
///     infer from the tap-to-Maps title.
///   • Bottom-right: small tertiary date
///
/// Color is reserved for signal: green for inflows (handled by
/// `AmountText`), blue for the tappable title and ⓘ.
struct TransactionRow: View {
    let transaction: Transaction

    /// Maximum number of characters before we tail-truncate the raw payee.
    /// Long enough to read short business names; short enough that a
    /// "GOOGLE PLAY INDIA PRIVATE LIMITED" string doesn't push the amount
    /// off the screen.
    private static let merchantTitleLineLimit: Int = 1

    @State private var showPlacesPopover: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MerchantAvatar(merchantName: transaction.displayMerchant, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                titleRow

                Text(categoryText)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary)
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
    }

    /// Title + (↗) + (ⓘ). The title text shows the *raw* payee (e.g. the UPI
    /// name on the bank email) so the user always sees what their bank sees;
    /// the Places-resolved business name is one tap away on the ⓘ button.
    /// When coords exist, tapping the title opens Maps directly.
    @ViewBuilder
    private var titleRow: some View {
        HStack(spacing: 6) {
            titleLabel
                .layoutPriority(1)

            if transaction.hasResolvedMerchant {
                Button {
                    showPlacesPopover.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AppColor.tap)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPlacesPopover, arrowEdge: .top) {
                    placesInfoPopover
                        .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("Show resolved business name")
            }

            Spacer(minLength: 0)
        }
    }

    /// The title itself. Tappable when we have coords (opens Maps + shows
    /// a tiny `↗`); plain text otherwise. We use the raw payee here so the
    /// title remains stable across pipeline tiers.
    @ViewBuilder
    private var titleLabel: some View {
        if transaction.hasCoordinates,
           let lat = transaction.locationLat,
           let lng = transaction.locationLng {
            Button {
                MapsLinker.open(
                    latitude: lat,
                    longitude: lng,
                    label: transaction.displayMerchant
                )
            } label: {
                HStack(spacing: 3) {
                    Text(titleText)
                        .font(AppFont.rowTitle)
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(Self.merchantTitleLineLimit)
                        .truncationMode(.tail)
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppColor.tap)
                }
            }
            .buttonStyle(.plain)
        } else {
            Text(titleText)
                .font(AppFont.rowTitle)
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(Self.merchantTitleLineLimit)
                .truncationMode(.tail)
        }
    }

    /// Title text shown on the row. When we have a Places resolution, prefer
    /// the raw payee (preserves what the bank actually said); otherwise just
    /// show whatever the row holds.
    private var titleText: String {
        if transaction.hasResolvedMerchant, !transaction.merchantRaw.isEmpty {
            return transaction.merchantRaw
        }
        return transaction.displayMerchant
    }

    /// Popover content shown when the user taps the ⓘ. Surface the Places
    /// resolved name as the headline since that's the value-add over the
    /// raw payee; below it, the coords + a tap-to-open-Maps row so the
    /// popover is self-contained.
    @ViewBuilder
    private var placesInfoPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("from nearby places")
                .font(.system(size: 10, weight: .semibold).smallCaps())
                .foregroundStyle(AppColor.textTertiary)

            Text(transaction.merchantNormalized)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            if transaction.hasCoordinates,
               let lat = transaction.locationLat,
               let lng = transaction.locationLng {
                Button {
                    MapsLinker.open(
                        latitude: lat,
                        longitude: lng,
                        label: transaction.merchantNormalized
                    )
                    showPlacesPopover = false
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "map")
                            .font(.system(size: 11, weight: .medium))
                        Text("open in maps")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(AppColor.tap)
                }
                .buttonStyle(.plain)

                Text(String(format: "%.5f, %.5f", lat, lng))
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: 260, alignment: .leading)
    }

    private var categoryText: String {
        transaction.category?.shortName.lowercased() ?? "uncategorized"
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
