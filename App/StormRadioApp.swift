import SwiftUI
import StormRadioCore

@main
struct StormRadioApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Storm Radio \(AppSettings.defaults.profiles.count) profiles")
        }
    }
}
