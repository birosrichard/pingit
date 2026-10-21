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
                .environment(lifecycle.notifications)
        }
    }
}

@MainActor
final class PingitAppDelegate: NSObject, NSApplicationDelegate {
    let connection = GitHubConnection()
    let notifications = NotificationCoordinator(service: NativeNotificationService(),
        preferences: NotificationPreferences(defaults: .standard))
    private var restoration: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        notifications.start(dashboard: connection.dashboard)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { [notifications] in await notifications.refreshAuthorization() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        connection.dashboard.startBackgroundSync()
        restoration = Task { [connection, notifications] in
            await notifications.refreshAuthorization()
            await connection.restore()
        }
    }

    @objc private func willSleep(_ notification: Notification) { connection.dashboard.systemWillSleep() }
    @objc private func didWake(_ notification: Notification) { connection.dashboard.systemDidWake() }

    func applicationWillTerminate(_ notification: Notification) {
        restoration?.cancel()
        restoration = nil
        notifications.stop()
        connection.dashboard.shutdown()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
