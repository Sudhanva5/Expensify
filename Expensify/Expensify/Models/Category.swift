import Foundation
import SwiftUI

// V1's seven fixed categories. Mirrors the backend's CATEGORIES const.
enum Category: String, CaseIterable, Identifiable, Codable, Hashable {
    case travel = "Travel"
    case food = "Food"
    case entertainment = "Entertainment"
    case groceries = "Groceries / Kirana Stores"
    case personalTransfer = "Personal Transfer (Peer-to-Peer)"
    case investments = "Investments"
    case subscriptions = "Subscriptions"

    var id: String { rawValue }

    /// Short label for tight spaces (transaction rows, budget cards).
    var shortName: String {
        switch self {
        case .travel: return "Travel"
        case .food: return "Food"
        case .entertainment: return "Entertainment"
        case .groceries: return "Groceries"
        case .personalTransfer: return "P2P"
        case .investments: return "Investments"
        case .subscriptions: return "Subscriptions"
        }
    }

    /// SF Symbol for the category, used in chips and category rows.
    var symbolName: String {
        switch self {
        case .travel: return "airplane"
        case .food: return "fork.knife"
        case .entertainment: return "popcorn"
        case .groceries: return "basket"
        case .personalTransfer: return "person.2"
        case .investments: return "chart.line.uptrend.xyaxis"
        case .subscriptions: return "rectangle.stack.badge.play"
        }
    }

    /// Tint color used for chips and bars. Stays inside iOS system palette.
    var tint: Color {
        switch self {
        case .travel: return .blue
        case .food: return .orange
        case .entertainment: return .pink
        case .groceries: return .green
        case .personalTransfer: return .purple
        case .investments: return .indigo
        case .subscriptions: return .teal
        }
    }
}
