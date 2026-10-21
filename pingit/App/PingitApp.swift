import SwiftUI

@main
struct PingitApp: App {
    @NSApplicationDelegateAdaptor(PingitAppDelegate.self) private var lifecycle

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(lifecycle.connection)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .accessibilityLabel(lifecycle.connection.account == nil ? "pingit — Not connected" : "pingit — Connected")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(lifecycle.connection)
        }
    }
}

@MainActor
final class PingitAppDelegate: NSObject, NSApplicationDelegate {
    let connection = GitHubConnection()
    private var restoration: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        connection.dashboard.startBackgroundSync()
        restoration = Task { [connection] in await connection.restore() }
    }

    @objc private func willSleep(_ notification: Notification) { connection.dashboard.systemWillSleep() }
    @objc private func didWake(_ notification: Notification) { connection.dashboard.systemDidWake() }

    func applicationWillTerminate(_ notification: Notification) {
        restoration?.cancel()
        restoration = nil
        connection.dashboard.shutdown()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
