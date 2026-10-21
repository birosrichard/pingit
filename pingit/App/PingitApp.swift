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
        MenuBarExtra(connection.account == nil ? "pingit — Not connected" : "pingit — Connected",
                     systemImage: connection.account == nil ? "bell.slash" : "bell") {
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
