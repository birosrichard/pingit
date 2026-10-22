import AppKit
import UserNotifications

@MainActor
struct NotificationActivation {
    var openURL: (URL) -> Bool

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    nonisolated static func responseURL(identifier: String, isDefaultAction: Bool, urlString: String?) -> String? {
        guard isDefaultAction,
              identifier.hasPrefix("pingit.change.") || identifier.hasPrefix("pingit.debug."),
              let urlString, GitHubNotificationURL.validate(urlString) != nil else { return nil }
        return urlString
    }

    @discardableResult
    func activate(_ string: String) -> Bool {
        guard let url = GitHubNotificationURL.validate(string) else { return false }
        return openURL(url)
    }
}

// No actor-isolated framework conformance and no mutable delegate state. Objective-C
// callbacks may arrive on any queue; extract strings there before hopping to MainActor.
final class NativeNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let activate: @MainActor @Sendable (String) -> Void

    init(activate: @escaping @MainActor @Sendable (String) -> Void) {
        self.activate = activate
        super.init()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        guard let string = NotificationActivation.responseURL(
            identifier: response.notification.request.identifier,
            isDefaultAction: response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            urlString: response.notification.request.content.userInfo["pullRequestURL"] as? String
        ) else {
            completionHandler()
            return
        }
        let activate = activate
        Task { @MainActor in
            activate(string)
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        // Content.sound controls whether requesting sound has any effect.
        completionHandler([.banner, .list, .sound])
    }
}
