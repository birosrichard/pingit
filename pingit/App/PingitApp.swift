import SwiftUI
import UserNotifications

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
    private var notificationDelegate: NativeNotificationDelegate?
    private var permissionRefresh: Task<Void, Never>?
    private var restoration: Task<Void, Never>?

    func applicationWillFinishLaunching(_ notification: Notification) {
        let delegate = NativeNotificationDelegate { string in
            NotificationActivation().activate(string)
        }
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
        notifications.start(dashboard: connection.dashboard)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshNotificationAuthorization()
    }

    private func refreshNotificationAuthorization() {
        permissionRefresh?.cancel()
        permissionRefresh = Task { [notifications] in await notifications.refreshAuthorization() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        connection.dashboard.startBackgroundSync()
        refreshNotificationAuthorization()
        restoration = Task { [connection] in await connection.restore() }
    }

    @objc private func willSleep(_ notification: Notification) { connection.dashboard.systemWillSleep() }
    @objc private func didWake(_ notification: Notification) { connection.dashboard.systemDidWake() }

    func applicationWillTerminate(_ notification: Notification) {
        restoration?.cancel()
        restoration = nil
        permissionRefresh?.cancel()
        permissionRefresh = nil
        UNUserNotificationCenter.current().delegate = nil
        notificationDelegate = nil
        notifications.stop()
        connection.dashboard.shutdown()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
