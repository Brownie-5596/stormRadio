import SwiftUI
import StormRadioCore

@main
struct StormRadioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { NotificationService.shared.requestPermission() }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            RadioView()
                .tabItem { Label("Radio", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppModel.Tab.radio)
            FeedView()
                .tabItem { Label("Feed", systemImage: "list.bullet.rectangle") }
                .tag(AppModel.Tab.feed)
            ProductsView()
                .tabItem { Label("Products", systemImage: "doc.text.magnifyingglass") }
                .tag(AppModel.Tab.products)
            MapScreen()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(AppModel.Tab.map)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(AppModel.Tab.settings)
        }
    }
}
