import Foundation

/// One card in the swipe-review stack. Carries the transaction plus the
/// system's suggested category + the "why?" rationale.
struct ReviewItem: Identifiable, Hashable {
    let id: String
    let transaction: Transaction
    let suggestedCategory: Category?
    let suggestionDetail: String?

    init(
        id: String = UUID().uuidString,
        transaction: Transaction,
        suggestedCategory: Category? = nil,
        suggestionDetail: String? = nil
    ) {
        self.id = id
        self.transaction = transaction
        self.suggestedCategory = suggestedCategory ?? transaction.category
        self.suggestionDetail = suggestionDetail
    }
}

/// Captured when the user swipes left on a card — needs explicit tagging.
/// Becomes a row in the post-swipe tagging list.
struct PendingTag: Identifiable, Hashable {
    let id: String
    let transaction: Transaction
    var chosenCategory: Category

    init(item: ReviewItem) {
        self.id = item.id
        self.transaction = item.transaction
        // Default the dropdown to whatever the system suggested.
        self.chosenCategory = item.suggestedCategory ?? .food
    }
}
