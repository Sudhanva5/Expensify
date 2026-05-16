import Foundation

/// A user-authored rule that auto-tags transactions matching its
/// conditions. Mirrors the backend's UserRule model + RuleConditions.
///
/// Rules let the user encode contextual knowledge the categorizer
/// can't infer from the payee string alone — the canonical example
/// being "any UPI payment of ₹100-400 within 50m of my office on a
/// weekday morning is almost certainly a Rapido ride." The categorizer
/// sees the merchant; the rule sees the *situation*.
struct UserRule: Identifiable, Hashable {
    let id: String
    var name: String
    var priority: Int
    var enabled: Bool
    var conditions: Conditions
    var category: Category
    /// Auto-tag confidence the rule asserts when it fires. Anything
    /// ≥ 0.95 triggers an auto-tag in recategorizeWithLocation; lower
    /// values surface in the review queue as suggestions.
    var confidence: Double
    var hitCount: Int

    struct Conditions: Hashable, Codable {
        var direction: String?               // "in" | "out"
        var instrument: [String]?            // nil = any
        var amountBetween: [Double]?         // [low, high] in major units (rupees)
        var timeOfDayBetween: [String]?      // ["HH:MM", "HH:MM"] IST
        var dayOfWeek: [String]?             // ["Mon"…"Sun"]
        var payeeContains: String?
        var payeeRegex: String?
        var payeeNotInAliasTable: Bool?
        var vpaShape: String?                // "personal" | "merchant" | "unknown"
        var locationWithinRadius: LocationCondition?

        struct LocationCondition: Hashable, Codable {
            var lat: Double
            var lng: Double
            var meters: Double
        }
    }
}

extension UserRule.Conditions {
    /// Build a sensible pre-fill for "create rule from this transaction":
    ///   - direction matches the tx
    ///   - amount window ±20% (clamped to one decimal)
    ///   - same instrument
    ///   - time window ±1h IST (HH:MM)
    ///   - location radius ON if we have coordinates (default 100m — wide
    ///     enough for a typical pickup zone but narrow enough to exclude
    ///     the next plaza)
    static func suggestion(from tx: Transaction) -> UserRule.Conditions {
        let amount = NSDecimalNumber(decimal: tx.amountInr).doubleValue
        let low = max(0, (amount * 0.8).rounded())
        let high = (amount * 1.2).rounded()

        let cal = Calendar(identifier: .gregorian)
        let ist = TimeZone(identifier: "Asia/Kolkata") ?? .current
        var c = cal
        c.timeZone = ist
        let comps = c.dateComponents([.hour, .minute], from: tx.occurredAt)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let centerMins = hour * 60 + minute
        let startMins = max(0, centerMins - 60)
        let endMins = min(24 * 60 - 1, centerMins + 60)
        let startHHMM = String(format: "%02d:%02d", startMins / 60, startMins % 60)
        let endHHMM = String(format: "%02d:%02d", endMins / 60, endMins % 60)

        var location: LocationCondition? = nil
        if let lat = tx.locationLat, let lng = tx.locationLng {
            location = LocationCondition(lat: lat, lng: lng, meters: 100)
        }

        return UserRule.Conditions(
            direction: tx.direction.rawValue,
            instrument: [tx.instrument],
            amountBetween: [low, high],
            timeOfDayBetween: [startHHMM, endHHMM],
            dayOfWeek: nil,
            payeeContains: nil,
            payeeRegex: nil,
            payeeNotInAliasTable: nil,
            vpaShape: nil,
            locationWithinRadius: location
        )
    }

    /// Short human summary for list rows ("₹100-400, near office, 8-10am").
    var summary: String {
        var parts: [String] = []
        if let amt = amountBetween, amt.count == 2 {
            parts.append("₹\(Int(amt[0]))-\(Int(amt[1]))")
        }
        if locationWithinRadius != nil {
            parts.append("near a place")
        }
        if let t = timeOfDayBetween, t.count == 2 {
            parts.append("\(t[0])-\(t[1])")
        }
        if let days = dayOfWeek, !days.isEmpty {
            parts.append(days.joined(separator: "/"))
        }
        if parts.isEmpty { return "all transactions" }
        return parts.joined(separator: " · ")
    }
}
