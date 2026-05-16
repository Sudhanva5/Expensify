import Foundation

/// A receipt email (from Swiggy / Amazon / Zomato / etc.) that the
/// backend's `processReceiptEmail` pipeline matched to a transaction.
/// Rendered in the bottom-sheet "more details" card.
///
/// Two modes of richness depending on which extractor ran:
///   - **Structured** (Swiggy parser hit): `items` populated, `meta`
///     has journey-from/to → renders an inline order summary
///   - **Snippet-only** (universal regex or no extraction): just
///     `subject`, `snippet`, maybe `amountInr` + `orderId` → renders
///     a Gmail-preview-style card with a "Open in Gmail" button
struct ReceiptDetails: Hashable, Codable {
    let id: String
    let gmailMessageId: String
    let source: String       // "swiggy", "amazon", "zomato", "bookmyshow", etc.
    let subject: String
    let snippet: String
    let receivedAt: Date
    let fromAddress: String?
    let amountInr: Decimal?
    let orderId: String?
    let items: [ReceiptItem]?
    let fees: [ReceiptFee]?
    let meta: ReceiptMeta?

    /// True when we have enough to render the rich card (items list).
    /// Otherwise fall back to the snippet-style card.
    var hasStructuredItems: Bool {
        (items?.isEmpty == false)
    }

    /// Universal Gmail web URL that opens this specific message. iOS
    /// universal-link routing sends it to the Gmail app if installed,
    /// otherwise Safari.
    var gmailWebURL: URL? {
        URL(string: "https://mail.google.com/mail/u/0/#inbox/\(gmailMessageId)")
    }
}

struct ReceiptItem: Hashable, Codable {
    let name: String
    let qty: Int
    let priceInr: Decimal

    enum CodingKeys: String, CodingKey {
        case name, qty
        case priceInr = "priceInr"
    }
}

struct ReceiptFee: Hashable, Codable {
    let name: String
    let amountInr: Decimal

    enum CodingKeys: String, CodingKey {
        case name
        case amountInr = "amountInr"
    }
}

/// Loose container for per-merchant extras. Swiggy populates
/// `journeyFrom` / `journeyTo` for the restaurant + delivery addresses;
/// other merchants leave these nil and may add their own fields later.
struct ReceiptMeta: Hashable, Codable {
    let journeyFrom: JourneyEntry?
    let journeyTo: JourneyEntry?

    enum CodingKeys: String, CodingKey {
        case journeyFrom, journeyTo
    }
}

struct JourneyEntry: Hashable, Codable {
    let text: String
    let timestamp: String
}
