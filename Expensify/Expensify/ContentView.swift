import SwiftUI

/// Root view. 3-tab TabView. Settings is presented as a sheet from any tab
/// when the user taps the avatar in the nav bar.
struct ContentView: View {
    @State private var selection: Tab = .home
    @State private var showSettings = false

    enum Tab: Hashable {
        case home, categories, activity
    }

    private var pendingReviewCount: Int {
        MockData.transactions.filter { $0.status == .pendingReview }.count
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
                .badge(pendingReviewCount)
                .tag(Tab.activity)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
}
