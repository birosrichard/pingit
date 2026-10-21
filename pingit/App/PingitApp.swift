import SwiftUI

@main
struct PingitApp: App {
    var body: some Scene {
        MenuBarExtra("pingit", systemImage: "bell.badge") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
