import Foundation

/// User-selectable date scope for the Home and Categories tabs.
enum DateRange: Hashable {
    /// No date filter — every transaction the store has loaded shows up.
    /// The home list groups them into month sections regardless of scope,
    /// so `.all` reads as a continuous timeline of every spend.
    case all
    case day(Date)
    case month(year: Int, month: Int)
    case custom(start: Date, end: Date)

    /// Default to the current calendar month.
    static var defaultRange: DateRange {
        let comps = Calendar.current.dateComponents([.year, .month], from: Date())
        return .month(year: comps.year ?? 2026, month: comps.month ?? 5)
    }

    /// User-facing label rendered in the filter dropdown.
    var label: String {
        let df = DateFormatter()
        switch self {
        case .all:
            return "all transactions"
        case .day(let date):
            df.dateFormat = "d MMM yyyy"
            return df.string(from: date)
        case .month(let year, let month):
            df.dateFormat = "MMMM yyyy"
            let comps = DateComponents(year: year, month: month, day: 1)
            return df.string(from: Calendar.current.date(from: comps) ?? Date())
        case .custom(let start, let end):
            df.dateFormat = "d MMM"
            return "\(df.string(from: start)) – \(df.string(from: end))"
        }
    }

    /// Is the given timestamp inside this range?
    func contains(_ date: Date) -> Bool {
        let cal = Calendar.current
        switch self {
        case .all:
            return true
        case .day(let day):
            return cal.isDate(date, inSameDayAs: day)
        case .month(let year, let month):
            let comps = cal.dateComponents([.year, .month], from: date)
            return comps.year == year && comps.month == month
        case .custom(let start, let end):
            let startOfDay = cal.startOfDay(for: start)
            let endOfDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: end)) ?? end
            return date >= startOfDay && date < endOfDay
        }
    }
}
