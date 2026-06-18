import Foundation

/// Snapshot of one account's available balance, populated server-side by
/// parsing HDFC's "Account update" InstaAlert emails. iOS renders a card
/// above the transaction list with the freshest entry.
struct AccountBalance: Sendable, Equatable, Identifiable {
    /// Use the instrument as id so the SwiftUI list-style diffing has a
    /// stable key across refreshes.
    var id: String { instrument }
    let instrument: String
    let balanceInr: Decimal
    /// "As of" timestamp HDFC reports in the email body. Often a
    /// calendar date with no time component — server inherits the
    /// receivedAt hh:mm:ss so this sorts correctly alongside
    /// transactions.
    let asOf: Date
    /// When the row was last touched server-side (basically when the
    /// most recent balance email arrived). Lets the UI render
    /// "checked Nm ago" for the refresh-button affordance.
    let updatedAt: Date

    /// Last four digits of the account number, parsed from the
    /// instrument string ("account_5264" → "5264"). Falls back to
    /// the full instrument when the prefix doesn't match.
    var lastFour: String {
        let parts = instrument.split(separator: "_")
        return parts.last.map(String.init) ?? instrument
    }
}
