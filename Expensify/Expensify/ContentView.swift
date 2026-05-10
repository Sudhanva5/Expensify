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
                    Label("Home", systemImage: selection == .home ? "house.fill" : "house")
                }
                .tag(Tab.home)

            CategoriesView(showSettings: $showSettings)
                .tabItem {
                    Label("Categories", systemImage: selection == .categories ? "chart.pie.fill" : "chart.pie")
                }
                .tag(Tab.categories)

            ActivityView(showSettings: $showSettings)
                .tabItem {
                    Label("Activity", systemImage: selection == .activity ? "bell.fill" : "bell")
                }
                .badge(store.reviewItems.count)
                .tag(Tab.activity)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environment(TransactionStore())
}
