import SwiftUI

@main
struct GitPinglyApp: App {
    var body: some Scene {
        MenuBarExtra("GitPingly", systemImage: "bell.badge") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
