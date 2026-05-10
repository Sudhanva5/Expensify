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
        case groq
        case braveGroq = "brave_groq"

        /// Human-readable "why?" tag for the review card.
        var label: String {
            switch self {
            case .alias: return "Known merchant"
            case .autopayAlias: return "Autopay"
            case .vpaShape: return "VPA pattern"
            case .userRule: return "Your rule"
            case .merchantPattern: return "Past tagging"
            case .groq, .braveGroq: return "AI suggestion"
            }
        }
    }
}

extension Transaction {
    /// Display-friendly merchant: prefers normalized over raw when shorter.
    var displayMerchant: String {
        if !merchantNormalized.isEmpty,
           merchantNormalized.count < merchantRaw.count {
            return merchantNormalized
        }
        return merchantRaw
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
