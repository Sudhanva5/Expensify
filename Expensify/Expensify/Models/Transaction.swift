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
    /// Optional Gmail-sourced receipt linked to this transaction.
    /// Populated when an order email from Swiggy / Amazon / etc. landed
    /// in the user's inbox AND the backend matched it by amount +
    /// timestamp. Used by the bottom-sheet "more details" to render the
    /// receipt card (items + Gmail deep link).
    var receipt: ReceiptDetails? = nil
    /// Optional list of nearby Google Places candidates from the
    /// recategorize pass. Kept even when ambiguity prevented an
    /// auto-tag — iOS shows them as a "Nearby places" picker so the
    /// user can claim the right one with one tap.
    var placesSuggestions: [PlaceSuggestion]? = nil
    /// Optional freeform note the user typed in the detail sheet.
    /// Surfaced to the LLM via MCP so spend-history questions can be
    /// grounded in the user's own annotation when one exists. Empty
    /// strings are normalised to nil by the backend.
    var notes: String? = nil
    /// Merchant decoded from an aggregator-minted VPA, supplied by the
    /// backend only when HDFC's merchant text was a bare echo of the VPA
    /// itself. Consumed by `displayMerchant` as a fallback beneath the
    /// bank/Places/user name, never as an override of one.
    var vpaMerchant: String? = nil
    /// Payment aggregator that routed this UPI payment ("PayU", "Razorpay").
    /// Display-only trace — shown in the detail sheet so a spend can be
    /// traced back to the checkout it came from.
    var vpaGateway: String? = nil

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
        // Places / alias / user renames still win outright.
        if !merchantNormalized.isEmpty,
           merchantNormalized.caseInsensitiveCompare(merchantRaw) != .orderedSame {
            return merchantNormalized
        }
        // Nothing better on file, and the bank only echoed the VPA back at
        // us ("snitchapparelsp711507.rzp"). The gateway-decoded name is
        // strictly more readable than that. The backend already checked the
        // echo condition — a populated vpaMerchant means it's safe to use.
        if let vpaMerchant, !vpaMerchant.isEmpty {
            return vpaMerchant
        }
        return merchantRaw
    }

    /// Stable key for favicon lookup, deliberately decoupled from
    /// `displayMerchant`. Tracks the *bank-side* identity so renaming a row
    /// to "Manju Tea Stall" doesn't chase a Manju favicon and drop the
    /// stable Paytm-QR / brand logo.
    ///
    /// The gateway-decoded name is allowed in here (unlike a user rename)
    /// precisely because it IS bank-side — it's derived from the VPA HDFC
    /// sent us. It also comes first, because a raw payee that's a bare VPA
    /// echo ("snitchapparelsp711507.rzp") resolves no favicon at all,
    /// whereas "Snitch" resolves the real one.
    var brandKey: String {
        if let vpaMerchant, !vpaMerchant.isEmpty { return vpaMerchant }
        if !merchantRaw.isEmpty { return merchantRaw }
        return vpa ?? ""
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
