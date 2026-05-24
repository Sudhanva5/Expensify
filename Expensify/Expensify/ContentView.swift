import SwiftUI

/// Root view. 3-tab TabView. Settings is presented as a sheet from any tab
/// when the user taps the avatar in the nav bar.
struct ContentView: View {
    @Environment(TransactionStore.self) private var store
    @State private var selection: Tab = .home
    @State private var showSettings = false

    enum Tab: Hashable {
        case home, categories, activity
    }

    var body: some View {
        TabView(selection: $selection) {
            HomeView(showSettings: $showSettings)
                .tabItem {
                    Label("home", systemImage: selection == .home ? "house.fill" : "house")
                }
                .tag(Tab.home)

            CategoriesView(showSettings: $showSettings)
                .tabItem {
                    Label("categories", systemImage: selection == .categories ? "chart.pie.fill" : "chart.pie")
                }
                .tag(Tab.categories)

            ActivityView(showSettings: $showSettings)
                .tabItem {
                    Label("review", systemImage: selection == .activity ? "bell.fill" : "bell")
                }
                .badge(store.reviewItems.count)
                .tag(Tab.activity)
        }
        // Tab bar's selected-tab tint. Using the accent (tap) blue
        // instead of primary text follows HIG — the selected indicator
        // should pop as the system accent, not blend with the body
        // copy. In light mode it's a saturated blue; in dark it's the
        // lifted brighter blue from AppColor.tap.
        .tint(AppColor.tap)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(TransactionStore())
}
