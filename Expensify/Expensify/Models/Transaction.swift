import Foundation

/// One row in the transaction log. Maps onto the backend's Transaction model.
/// In V1 these come from MockData; later they'll come from the Railway API.
struct Transaction: Identifiable, Hashable {
    let id: String
    let amountInr: Decimal
    let currency: String
    let merchantRaw: String
    let merchantNormalized: String
    let vpa: String?
    let direction: Direction
    let instrument: String
    let occurredAt: Date
    let category: Category?
    let confidence: Double?
    let signalSource: SignalSource?
    let status: Status
    let locationLat: Double?
    let locationLng: Double?
    let locationCity: String?
    let locationStatus: LocationStatus

    enum LocationStatus: String, Codable, Hashable {
        case awaiting
        case fulfilled
        case missed
        case notApplicable = "not_applicable"
    }

    enum Direction: String, Codable, Hashable {
        case `in`
        case out

        var isOutflow: Bool { self == .out }
    }

    enum Status: String, Codable, Hashable {
        case awaitingLocation = "awaiting_location"
        case pendingReview = "pending_review"
        case resolved
    }

    enum SignalSource: String, Codable, Hashable {
        case alias
        case autopayAlias = "autopay_alias"
        case vpaShape = "vpa_shape"
        case userRule = "user_rule"
        case merchantPattern = "merchant_pattern"
        /// Set by the backend's recategorizeWithLocation step — means we
        /// looked up nearby Google Places and one of them mapped to a V1
        /// category via the static type map. This is the only signal source
        /// where `merchantNormalized` carries an actual storefront name.
        case places

        /// Human-readable "why?" tag for the review card.
        var label: String {
            switch self {
            case .alias: return "Known merchant"
            case .autopayAlias: return "Autopay"
            case .vpaShape: return "VPA pattern"
            case .userRule: return "Your rule"
            case .merchantPattern: return "Past tagging"
            case .places: return "Nearby place"
            }
        }
    }
}

extension Transaction {
    /// Display-friendly merchant. Prefer the normalized name whenever it's
    /// distinct from the raw payee string — that's how the Places-resolved
    /// business name (e.g. "MTR Hotel Jayanagar") wins over the UPI payee
    /// name (e.g. "RAJESH KUMAR"). Falls back to raw when they're identical
    /// (which is the case before any resolution happens).
    var displayMerchant: String {
        if !merchantNormalized.isEmpty,
           merchantNormalized.caseInsensitiveCompare(merchantRaw) != .orderedSame {
            return merchantNormalized
        }
        return merchantRaw
    }

    /// True if we have a Places-resolved business name distinct from the raw payee.
    var hasResolvedMerchant: Bool {
        !merchantNormalized.isEmpty &&
        merchantNormalized.caseInsensitiveCompare(merchantRaw) != .orderedSame
    }

    /// True if the row was enriched by the Places + location flow. Used as
    /// the stronger gate for "show the info button" — covers the edge case
    /// where the Places display name happens to equal the raw payee string.
    var wasPlacesResolved: Bool {
        signalSource == .places
    }

    /// Should we surface the small ⓘ next to the title? Either we have a
    /// different normalized name on file, or the signalSource tells us this
    /// row went through the Places step.
    var shouldShowPlacesInfoButton: Bool {
        wasPlacesResolved || hasResolvedMerchant
    }

    /// True if lat/lng were actually captured (not just "awaiting" or "missed").
    var hasCoordinates: Bool {
        locationLat != nil && locationLng != nil
    }

    /// True if this transaction is in the review queue.
    var needsReview: Bool { status == .pendingReview }

    /// Signed amount: outflows are negative, inflows positive.
    var signedAmount: Decimal {
        direction == .out ? -amountInr : amountInr
    }

    /// Short string for the location chip: prefers city, falls back to coords.
    /// Returns nil if no location was captured.
    var locationLabel: String? {
        if let city = locationCity, !city.isEmpty { return city }
        if let lat = locationLat, let lng = locationLng {
            return String(format: "%.3f, %.3f", lat, lng)
        }
        return nil
    }
}
