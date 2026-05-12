import Foundation

/// Single source of truth for budgets across the app. Persists to Railway
/// via APIClient. Views subscribe via `@Environment(BudgetStore.self)`.
@MainActor
@Observable
final class BudgetStore {
    /// Backend-known budgets, keyed by category. A category absent from
    /// this dictionary means "no budget set yet".
    private var byCategory: [Category: Budget] = [:]

    var isLoading: Bool = false
    var loadError: String? = nil

    /// Returns the budget for a category, or a default "not-set" placeholder.
    func budget(for category: Category) -> Budget {
        if let b = byCategory[category] { return b }
        return Budget(category: category, monthlyLimitInr: nil)
    }

    /// All categories with budgets actually set (limit > 0).
    var configured: [Budget] {
        Category.allCases.compactMap { cat in
            guard let b = byCategory[cat], b.isSet else { return nil }
            return b
        }
    }

    /// Pull all budgets from the backend.
    func refresh() async {
        isLoading = true
        loadError = nil
        do {
            let fetched = try await APIClient.shared.fetchBudgets()
            var map: [Category: Budget] = [:]
            for b in fetched {
                map[b.category] = b
            }
            byCategory = map
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    /// Optimistic upsert — update local state immediately, fire-and-forget
    /// the network call. On failure, refresh from backend to recover.
    func upsert(_ budget: Budget) async {
        byCategory[budget.category] = budget
        do {
            let saved = try await APIClient.shared.upsertBudget(budget)
            byCategory[budget.category] = saved
        } catch {
            #if DEBUG
            print("[BudgetStore] upsert failed for \(budget.category.rawValue): \(error)")
            #endif
            await refresh()
        }
    }

    /// Remove a budget for a category.
    func remove(_ category: Category) async {
        byCategory.removeValue(forKey: category)
        do {
            try await APIClient.shared.deleteBudget(category: category)
        } catch {
            #if DEBUG
            print("[BudgetStore] delete failed: \(error)")
            #endif
            await refresh()
        }
    }
}
