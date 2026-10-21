import SwiftUI

@main
struct PingitApp: App {
    @State private var connection: GitHubConnection

    init() {
        let connection = GitHubConnection()
        _connection = State(initialValue: connection)
        Task { await connection.restore() }
    }

    var body: some Scene {
        MenuBarExtra("pingit", systemImage: "bell.badge") {
            MenuBarView()
                .environment(connection)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(connection)
        }
    }
}
