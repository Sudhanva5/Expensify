import Foundation

/// A monthly spending limit for one category.
struct Budget: Identifiable, Hashable {
    let id: String
    let category: Category
    var monthlyLimitInr: Decimal?
    var alertAt80: Bool
    var alertAt100: Bool
    var alertAt110: Bool

    init(
        id: String = UUID().uuidString,
        category: Category,
        monthlyLimitInr: Decimal? = nil,
        alertAt80: Bool = true,
        alertAt100: Bool = true,
        alertAt110: Bool = true
    ) {
        self.id = id
        self.category = category
        self.monthlyLimitInr = monthlyLimitInr
        self.alertAt80 = alertAt80
        self.alertAt100 = alertAt100
        self.alertAt110 = alertAt110
    }

    var isSet: Bool { monthlyLimitInr != nil && (monthlyLimitInr ?? 0) > 0 }
}
