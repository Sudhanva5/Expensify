import Foundation

/// Single source of truth for transactions across all tabs. Backed by the
/// Railway API. Views observe via `@Environment(TransactionStore.self)` and
/// trigger refreshes through `.task`/`.refreshable`.
@MainActor
@Observable
final class TransactionStore {
    var transactions: [Transaction] = []
    var isLoading: Bool = false
    var loadError: String? = nil
    var lastFetchedAt: Date? = nil

    /// Items currently in the review queue.
    var reviewItems: [ReviewItem] {
        transactions
            .filter { $0.status == .pendingReview }
            .map { tx in
                let detail: String?
                switch tx.signalSource {
                case .userRule: detail = "Matched a rule"
                case .vpaShape: detail = "VPA looks personal"
                case .alias, .autopayAlias: detail = "Known merchant"
                case .merchantPattern: detail = "Tagged before"
                case .groq, .braveGroq: detail = "AI suggestion"
                case .none: detail = nil
                }
                return ReviewItem(
                    id: tx.id,
                    transaction: tx,
                    suggestedCategory: tx.category,
                    suggestionDetail: detail
                )
            }
    }

    /// Pull from the backend. Replaces in-memory state.
    func refresh() async {
        isLoading = true
        loadError = nil
        do {
            transactions = try await APIClient.shared.fetchTransactions()
            lastFetchedAt = Date()
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}
