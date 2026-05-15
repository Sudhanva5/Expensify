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
    /// When the current refresh started. The UI uses this to show a
    /// "still loading from <host>" diagnostic if a fetch hangs >5s,
    /// so the user can see *where* it's stuck without Xcode console.
    var refreshStartedAt: Date? = nil

    enum ConnectionState: Equatable {
        case idle
        case loading
        case ok
        case failing(message: String)
    }

    /// Host portion of the configured baseURL, surfaced for the in-app
    /// diagnostic banner. Lets the user verify they're on the rebuilt
    /// app (new custom-domain URL) vs. an older install.
    var baseHost: String {
        Constants.baseURL.host ?? "?"
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
        refreshStartedAt = Date()

        #if DEBUG
        print("[TransactionStore] refresh start → \(Constants.baseURL.absoluteString)")
        let t0 = Date()
        #endif

        do {
            transactions = try await APIClient.shared.fetchTransactions()
            lastFetchedAt = Date()
            connectionState = .ok
            refreshStartedAt = nil
            cancelAutoRetry()
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[TransactionStore] refresh ok → \(transactions.count) rows in \(ms)ms")
            #endif
        } catch {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[TransactionStore] refresh FAILED after \(ms)ms → \(error.localizedDescription)")
            #endif
            connectionState = .failing(message: error.localizedDescription)
            refreshStartedAt = nil
            scheduleAutoRetry()
        }
    }

    /// Optimistically retag a transaction. Updates the in-memory row first
    /// so the user sees the change instantly, then PATCHes the backend. On
    /// failure, refresh from the server to recover the true state.
    ///
    /// Called by the trailing-swipe category picker. Decoupled from the
    /// view layer so the sheet can fire-and-forget without awaiting.
    func retag(transactionId: String, to newCategory: Category) async {
        guard let idx = transactions.firstIndex(where: { $0.id == transactionId }) else {
            return
        }
        let original = transactions[idx]
        let updated = Transaction(
            id: original.id,
            amountInr: original.amountInr,
            currency: original.currency,
            merchantRaw: original.merchantRaw,
            merchantNormalized: original.merchantNormalized,
            vpa: original.vpa,
            direction: original.direction,
            instrument: original.instrument,
            occurredAt: original.occurredAt,
            category: newCategory,
            confidence: original.confidence,
            signalSource: original.signalSource,
            status: .resolved,
            locationLat: original.locationLat,
            locationLng: original.locationLng,
            locationCity: original.locationCity,
            locationStatus: original.locationStatus
        )
        transactions[idx] = updated

        do {
            try await APIClient.shared.confirmTransaction(
                id: transactionId,
                overrideCategory: newCategory
            )
        } catch {
            #if DEBUG
            print("[TransactionStore] retag failed for \(transactionId): \(error)")
            #endif
            // Pull authoritative state so we don't show a stale optimistic value.
            await refresh()
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
