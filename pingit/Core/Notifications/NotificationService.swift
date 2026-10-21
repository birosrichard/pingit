import Foundation
import UserNotifications

// Only value types cross the service boundary. No UNNotification object leaves the adapter.
struct NotificationMessage: Equatable, Sendable {
    let identifier: String
    let threadIdentifier: String
    let title: String
    let subtitle: String
    let body: String
    let pullRequestURL: String
    let sound: Bool
}

@MainActor
protocol NotificationService: AnyObject {
    func authorizationStatus() async -> NotificationPermission
    func requestAuthorization() async throws
    func deliver(_ message: NotificationMessage) async throws
}

@MainActor
final class NativeNotificationService: NotificationService {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func authorizationStatus() async -> NotificationPermission {
        // Map the Objective-C settings on its callback queue; transfer only a Sendable enum.
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let permission: NotificationPermission
                switch settings.authorizationStatus {
                case .notDetermined: permission = .notDetermined
                case .denied: permission = .denied
                case .authorized: permission = .authorized
                case .provisional: permission = .provisional
                @unknown default: permission = .unavailable
                }
                continuation.resume(returning: permission)
            }
        }
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func deliver(_ message: NotificationMessage) async throws {
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.subtitle = message.subtitle
        content.body = message.body
        content.threadIdentifier = message.threadIdentifier
        content.userInfo = ["pullRequestURL": message.pullRequestURL]
        if message.sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: message.identifier, content: content, trigger: nil)
        // Keep mutable framework objects inside this synchronous registration scope.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.add(request) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
