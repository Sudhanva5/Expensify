import Foundation

/// A nearby Google Places candidate surfaced as a tap-to-tag suggestion
/// when our auto-tagging logic wasn't confident enough to pick one
/// itself. Lives on `Transaction.placesSuggestions` and is rendered as
/// a "Nearby places" picker in the bottom-sheet detail.
struct PlaceSuggestion: Hashable, Codable {
    let name: String
    let category: String        // Backend's V1 category name (e.g. "Food")
    let distanceM: Int          // Haversine metres from the iPhone GPS
    let lat: Double?
    let lng: Double?
    let formattedAddress: String?

    /// Strongly-typed category, or nil if the backend returned a name
    /// we don't recognize (shouldn't happen but defensive).
    var resolvedCategory: Category? {
        Category(rawValue: category)
    }
}
