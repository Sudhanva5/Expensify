import SwiftUI

/// Receipt card rendered inside `TransactionDetailSheet` when the
/// backend has bound an order email to this transaction.
///
/// Two render modes based on what the extractor returned:
///   • **Structured** (Swiggy parser hit) — shows item list with
///     quantity and price, optional fee breakdown, and ORDER JOURNEY
///     addresses when present
///   • **Snippet-only** (other merchants / failed parse) — shows the
///     Gmail-preview-style sender + subject + first 2 lines of snippet
///
/// Both modes terminate in a single "Open in Gmail" button that deep-
/// links to the source email so the user can see the full receipt
/// natively in Gmail.
struct ReceiptCard: View {
    let receipt: ReceiptDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if receipt.hasStructuredItems {
                Divider().opacity(0.4)
                itemsSection
                if let fees = receipt.fees, !fees.isEmpty {
                    Divider().opacity(0.4)
                    feesSection(fees)
                }
                if let total = receipt.amountInr {
                    Divider().overlay(AppColor.hairline)
                    totalRow(total)
                }
            } else {
                Divider().opacity(0.4)
                snippetSection
            }
            openInGmailButton
        }
        .padding(14)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppColor.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            MerchantAvatar(merchantName: sourceDisplay, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceDisplay)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColor.textPrimary)
                Text(receivedAtFormatted)
                    .font(AppFont.caption)
                    .foregroundStyle(AppColor.textTertiary)
            }
            Spacer()
            if let amount = receipt.amountInr {
                Text(formatRupees(amount))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AppColor.textPrimary)
            }
        }
    }

    @ViewBuilder
    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(receipt.items ?? [], id: \.name) { item in
                HStack(alignment: .top) {
                    Text(item.qty > 1 ? "\(item.qty) × \(item.name)" : item.name)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.textPrimary)
                    Spacer()
                    Text(formatRupees(item.priceInr))
                        .font(.system(size: 13).monospacedDigit())
                        .foregroundStyle(AppColor.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func feesSection(_ fees: [ReceiptFee]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(fees, id: \.name) { fee in
                HStack {
                    Text(fee.name)
                        .font(AppFont.caption)
                        .foregroundStyle(AppColor.textTertiary)
                    Spacer()
                    Text(formatRupees(fee.amountInr))
                        .font(AppFont.caption.monospacedDigit())
                        .foregroundStyle(AppColor.textTertiary)
                }
            }
        }
    }

    @ViewBuilder
    private func totalRow(_ total: Decimal) -> some View {
        HStack {
            Text("Total")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            Text(formatRupees(total))
                .font(.system(size: 15, weight: .bold).monospacedDigit())
                .foregroundStyle(AppColor.textPrimary)
        }
    }

    @ViewBuilder
    private var snippetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(receipt.subject)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppColor.textPrimary)
                .lineLimit(2)
            Text(receipt.snippet)
                .font(AppFont.caption)
                .foregroundStyle(AppColor.textSecondary)
                .lineLimit(3)
            if let orderId = receipt.orderId {
                Text("Order \(orderId)")
                    .font(AppFont.caption.monospaced())
                    .foregroundStyle(AppColor.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var openInGmailButton: some View {
        if let url = receipt.gmailWebURL {
            Button {
                UIApplication.shared.open(url)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "envelope")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Open in Gmail")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(AppColor.tap.opacity(0.1))
                .foregroundStyle(AppColor.tap)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Helpers

    /// Human-readable source label. Falls back to capitalized source name
    /// for merchants we don't have a curated label for.
    private var sourceDisplay: String {
        switch receipt.source.lowercased() {
        case "swiggy": return "Swiggy"
        case "instamart": return "Swiggy Instamart"
        case "zomato": return "Zomato"
        case "amazon": return "Amazon"
        case "bookmyshow": return "BookMyShow"
        case "uber": return "Uber"
        case "cab": return "Cab"
        case "travel": return "Travel"
        case "airbnb": return "Airbnb"
        case "shopping": return "Shopping"
        case "grocery": return "Groceries"
        default: return receipt.source.prefix(1).uppercased() + receipt.source.dropFirst()
        }
    }

    private var receivedAtFormatted: String {
        let df = DateFormatter()
        df.dateFormat = "d MMM, h:mm a"
        return df.string(from: receipt.receivedAt)
    }

    private func formatRupees(_ amount: Decimal) -> String {
        let value = NSDecimalNumber(decimal: amount).doubleValue
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = value.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
        return "₹\(f.string(from: NSNumber(value: value)) ?? "\(value)")"
    }
}

#Preview {
    VStack(spacing: 16) {
        // Structured (Swiggy)
        ReceiptCard(receipt: ReceiptDetails(
            id: "r1",
            gmailMessageId: "abc123",
            source: "swiggy",
            subject: "Your Swiggy order was delivered superfast",
            snippet: "Order delivered! Belgian Waffle Co.",
            receivedAt: Date(),
            fromAddress: "noreply-orders@swiggy.in",
            amountInr: 308,
            orderId: "237743205871052",
            items: [
                ReceiptItem(name: "Triple Chocomelt Waffle", qty: 1, priceInr: 185)
            ],
            fees: [
                ReceiptFee(name: "Restaurant Packaging", amountInr: 10),
                ReceiptFee(name: "Platform fee with GST", amountInr: 17.58),
                ReceiptFee(name: "Delivery Fee", amountInr: 73),
                ReceiptFee(name: "Taxes", amountInr: 22.89)
            ],
            meta: nil
        ))

        // Snippet only
        ReceiptCard(receipt: ReceiptDetails(
            id: "r2",
            gmailMessageId: "def456",
            source: "amazon",
            subject: "Your Amazon order has shipped",
            snippet: "Your order #112-7892 has been shipped. Track your package…",
            receivedAt: Date(),
            fromAddress: "auto-confirm@amazon.in",
            amountInr: 1299,
            orderId: "112-7892",
            items: nil,
            fees: nil,
            meta: nil
        ))
    }
    .padding()
    .background(AppColor.canvas)
}
