//
//  ExpensifyApp.swift
//  Expensify
//

import SwiftUI

@main
struct ExpensifyApp: App {
    /// Wires UIKit's app-delegate callbacks (APNs token, silent push) into
    /// SwiftUI's lifecycle. AppDelegate handles all of it.
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    /// Shared store fetched from Railway. One instance, observed by every tab.
    @State private var transactionStore = TransactionStore()
    /// Single source of truth for budgets. Same instance is read by
    /// CategoriesView (progress bars) and SettingsView (edit list).
    @State private var budgetStore = BudgetStore()
    /// Local-only contact matcher. Reads device contacts, never syncs to
    /// the backend. Used to overlay friend names + DPs onto UPI rows.
    @State private var contactsService = ContactsService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(transactionStore)
                .environment(budgetStore)
                .environment(contactsService)
                .task {
                    await budgetStore.refresh()
                    // Prompt for contacts access on first launch — also
                    // builds the in-memory index on subsequent launches.
                    await contactsService.requestAccessAndLoad()
                }
                // Force the whole app to light. Per .impeccable.md, this is
                // a light-only product — money feels calmer in light, and
                // we haven't designed a dark palette. Without this, iOS
                // dark-mode settings would leak through (the inset-grouped
                // form on Settings was the most visible offender).
                .preferredColorScheme(.light)
        }
    }
}
