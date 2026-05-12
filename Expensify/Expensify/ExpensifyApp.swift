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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(transactionStore)
                // Force the whole app to light. Per .impeccable.md, this is
                // a light-only product — money feels calmer in light, and
                // we haven't designed a dark palette. Without this, iOS
                // dark-mode settings would leak through (the inset-grouped
                // form on Settings was the most visible offender).
                .preferredColorScheme(.light)
        }
    }
}
