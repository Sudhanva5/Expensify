//
//  ExpensifyApp.swift
//  Expensify
//

import SwiftUI
import UIKit

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

    /// User-controllable theme override. `.system` (default) follows the
    /// device-level Light/Dark setting; `.light` / `.dark` force the
    /// app independent of the device. Settings → Appearance writes this
    /// via @AppStorage, and the root view applies it below.
    @AppStorage(ThemePreference.storageKey) private var themeRaw: String =
        ThemePreference.system.rawValue

    init() {
        // SwiftUI's `.tint(AppColor.tap)` on TabView SHOULD color the
        // selected tab — and in iOS 17 / earlier 18 it does. But the
        // updated iOS 18 / 26 tab-bar implementation occasionally
        // ignores SwiftUI tint when the underlying UITabBar uses the
        // default appearance (selected items fall back to system
        // label, which renders white in dark mode — exactly the
        // "tab selector is white" report).
        //
        // Belt-and-suspenders: set the UITabBarItem appearance proxy
        // explicitly. Wrapping the SwiftUI Color in `UIColor(_:)`
        // preserves its dynamic light/dark provider, so this single
        // call colors the selected icon AND label correctly in both
        // appearances.
        let tintUIColor = UIColor(AppColor.tap)
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        for layout in [
            tabAppearance.stackedLayoutAppearance,
            tabAppearance.inlineLayoutAppearance,
            tabAppearance.compactInlineLayoutAppearance,
        ] {
            layout.selected.iconColor = tintUIColor
            layout.selected.titleTextAttributes = [.foregroundColor: tintUIColor]
        }
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(transactionStore)
                .environment(budgetStore)
                .environment(contactsService)
                .task {
                    await budgetStore.refresh()
                    // Hydrate VPA→contact pins from UserDefaults BEFORE
                    // the contacts index is built, so the first call to
                    // match(for:) already honours user overrides.
                    contactsService.loadPinsFromDefaults()
                    // Prompt for contacts access on first launch — also
                    // builds the in-memory index on subsequent launches.
                    await contactsService.requestAccessAndLoad()
                }
                // Theme override: AppColor tokens already adapt to the
                // active interface style; preferredColorScheme nudges
                // SwiftUI into resolving them with a forced light/dark
                // style when the user wants the app to ignore the
                // system setting. .system → nil → inherit.
                .preferredColorScheme(
                    ThemePreference(rawValue: themeRaw)?.colorScheme
                )
        }
    }
}
