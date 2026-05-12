import Foundation

/// Single source of truth for transactions across all tabs. Backed by the
/// Railway API via APIClient → HTTPClient. Exposes a rich `connectionState`
/// so views can show appropriate banners; auto-retries every 10 s when in
/// the .failing state.
@MainActor
@Observable
final class TransactionStore {
    var transactions: [Transaction] = []
    var connectionState: ConnectionState = .idle
    var lastFetchedAt: Date? = nil

    enum ConnectionState: Equatable {
        case idle
        case loading
        case ok
        case failing(message: String)
    }

    /// Back-compat conveniences for the views that already check these.
    var isLoading: Bool {
        if case .loading = connectionState { return true }
        return false
    }
    var loadError: String? {
        if case .failing(let msg) = connectionState { return msg }
        return nil
    }

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
                case .groq: detail = "AI suggestion"
                case .places: detail = "Nearby place"
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

    private var retryTask: Task<Void, Never>?
    private static let retryDelaySeconds: UInt64 = 10

    /// Pull from the backend. Replaces in-memory state on success; keeps
    /// previous data visible on failure so the user isn't dropped to a
    /// blank screen.
    func refresh() async {
        // Don't pile concurrent fetches
        if case .loading = connectionState { return }
        connectionState = .loading

        do {
            transactions = try await APIClient.shared.fetchTransactions()
            lastFetchedAt = Date()
            connectionState = .ok
            cancelAutoRetry()
        } catch {
            connectionState = .failing(message: error.localizedDescription)
            scheduleAutoRetry()
        }
    }

    // MARK: - Auto-retry

    private func scheduleAutoRetry() {
        cancelAutoRetry()
        retryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.retryDelaySeconds * 1_000_000_000)
            // After sleeping, only retry if we're still in the .failing
            // state (user might have manually retried in the meantime).
            if Task.isCancelled { return }
            if case .failing = connectionState {
                await refresh()
            }
        }
    }

    private func cancelAutoRetry() {
        retryTask?.cancel()
        retryTask = nil
    }
}
