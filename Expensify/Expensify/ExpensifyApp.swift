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
        }
    }
}
