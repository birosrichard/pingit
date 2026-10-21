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
        MenuBarExtra {
            MenuBarView()
                .environment(connection)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel(connection.account == nil ? "pingit — Not connected" : "pingit — Connected")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(connection)
        }
    }
}
