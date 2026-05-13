import Foundation

/// A monthly spending limit for one category.
///
/// Persistence:
///   - `id` is the Postgres row id (`Int`). For budgets that haven't been
///     created on the backend yet, this is `nil`.
///   - The three `alertAt*` booleans map to the backend's `alert_thresholds`
///     array — `0.8` ↔ alertAt80, `1.0` ↔ alertAt100, `1.1` ↔ alertAt110.
///     Any other thresholds returned by the backend are preserved verbatim
///     in `extraThresholds` so a save round-trip doesn't drop them.
struct Budget: Identifiable, Hashable {
    let id: String
    /// CUID assigned by Postgres/Prisma — string, not int. `nil` for
    /// budgets the user just authored client-side that haven't yet been
    /// persisted (rare; mostly a transient state during the upsert call).
    let backendId: String?
    let category: Category
    var monthlyLimitInr: Decimal?
    var alertAt80: Bool
    var alertAt100: Bool
    var alertAt110: Bool
    var enabled: Bool
    /// Thresholds returned by the backend that don't match the three
    /// canonical 80/100/110 toggles. Preserved on save round-trips.
    var extraThresholds: [Decimal]

    init(
        id: String = UUID().uuidString,
        backendId: String? = nil,
        category: Category,
        monthlyLimitInr: Decimal? = nil,
        alertAt80: Bool = true,
        alertAt100: Bool = true,
        alertAt110: Bool = true,
        enabled: Bool = true,
        extraThresholds: [Decimal] = []
    ) {
        self.id = id
        self.backendId = backendId
        self.category = category
        self.monthlyLimitInr = monthlyLimitInr
        self.alertAt80 = alertAt80
        self.alertAt100 = alertAt100
        self.alertAt110 = alertAt110
        self.enabled = enabled
        self.extraThresholds = extraThresholds
    }

    var isSet: Bool { monthlyLimitInr != nil && (monthlyLimitInr ?? 0) > 0 }

    /// Build the `alert_thresholds` array that the backend expects: the three
    /// canonical toggles (those that are on) plus any extras we preserved on
    /// the last fetch.
    var alertThresholdsForBackend: [Decimal] {
        var out: [Decimal] = []
        if alertAt80 { out.append(Decimal(0.8)) }
        if alertAt100 { out.append(Decimal(1.0)) }
        if alertAt110 { out.append(Decimal(1.1)) }
        out.append(contentsOf: extraThresholds)
        return out
    }

    /// Inverse of `alertThresholdsForBackend` — splits a returned array back
    /// into the three booleans + any leftover thresholds.
    static func fromBackendThresholds(_ thresholds: [Decimal]) -> (
        alertAt80: Bool,
        alertAt100: Bool,
        alertAt110: Bool,
        extras: [Decimal]
    ) {
        var alertAt80 = false
        var alertAt100 = false
        var alertAt110 = false
        var extras: [Decimal] = []
        for t in thresholds {
            // Equality on Decimal can be brittle if the backend stringifies
            // 0.8 with extra precision — compare via Double with a small tol.
            let d = NSDecimalNumber(decimal: t).doubleValue
            if abs(d - 0.8) < 0.001 {
                alertAt80 = true
            } else if abs(d - 1.0) < 0.001 {
                alertAt100 = true
            } else if abs(d - 1.1) < 0.001 {
                alertAt110 = true
            } else {
                extras.append(t)
            }
        }
        return (alertAt80, alertAt100, alertAt110, extras)
    }
}
