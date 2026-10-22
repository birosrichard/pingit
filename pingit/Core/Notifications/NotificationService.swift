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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            center.requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
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

// Notification payloads are untrusted again at activation, including after a cold launch.
enum GitHubNotificationURL {
    static func validate(_ string: String) -> URL? {
        guard string.utf8.count <= 2048, let parts = URLComponents(string: string),
              parts.scheme == "https", parts.host == "github.com",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.query == nil,
              parts.percentEncodedPath == parts.path else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard (path.count == 5 || path.count == 6), path[0].isEmpty,
              validComponent(path[1], repository: false), validComponent(path[2], repository: true),
              path[3] == "pull", let number = Int(path[4]), number > 0,
              path[4] == Substring(String(number)),
              path.count == 5 || path[5] == "files" else { return nil }
        let suffix = path.count == 6 ? "/files" : ""
        let fragment = parts.fragment.map { "#" + $0 } ?? ""
        if let anchor = parts.fragment {
            let prefix = anchor.hasPrefix("issuecomment-") ? "issuecomment-" : "discussion_r"
            let digits = anchor.dropFirst(prefix.count)
            guard anchor.hasPrefix(prefix), !digits.isEmpty, digits.first != "0",
                  digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  suffix.isEmpty || prefix == "discussion_r" else { return nil }
        } else if !suffix.isEmpty { return nil }
        guard string == "https://github.com/\(path[1])/\(path[2])/pull/\(number)" + suffix + fragment else { return nil }
        return parts.url
    }

    private static func validComponent(_ value: Substring, repository: Bool) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || (repository && ($0 == 46 || $0 == 95))
        }
    }
}

extension NotificationMessage {
    init?(event: PullRequestChangeEvent, sound: Bool) {
        guard !event.id.isEmpty, !event.pullRequestID.isEmpty, event.number > 0,
              let url = GitHubNotificationURL.validate(event.url.absoluteString),
              url.path == "/\(event.repository.nameWithOwner)/pull/\(event.number)"
                || (event.signal == .conversation && url.path == "/\(event.repository.nameWithOwner)/pull/\(event.number)/files"),
              event.signal != .conversation || url.fragment != nil else { return nil }
        identifier = "pingit.change.\(changeDigest(event.id))"
        threadIdentifier = "pingit.pr.\(changeDigest(event.pullRequestID))"
        title = switch event.kind {
        case .reviewRequested: "Review requested"
        case .reviewRequestRemoved: "Review request removed"
        case .approved: "Pull request approved"
        case .changesRequested: "Changes requested"
        case .readyForReview: "Ready for review"
        case .newPRComment: "New PR comment"
        case .newInlineReviewComment: "New inline review comment"
        case .newReviewThreadReply: "Reply in review thread"
        }
        subtitle = "\(event.repository.nameWithOwner) #\(event.number)"
        let prTitle = Self.text(event.title, limit: 180)
        let actor = Self.text(event.actorLogin, limit: 80)
        let context = prTitle.isEmpty ? "Pull request #\(event.number)" : prTitle
        if event.signal == .conversation {
            let who = actor.isEmpty ? "Someone" : "@\(actor)"
            body = event.kind == .newReviewThreadReply
                ? "\(who) replied to a discussion on #\(event.number)."
                : "\(who) commented on #\(event.number)."
        } else { body = actor.isEmpty ? context : "\(context) — @\(actor)" }
        pullRequestURL = url.absoluteString
        self.sound = sound
    }

    private static func text(_ value: String?, limit: Int) -> String {
        let clean = (value ?? "").unicodeScalars.map { scalar -> String in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: " "
            default: String(scalar)
            }
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return clean.count > limit ? String(clean.prefix(limit)) + "…" : clean
    }
}
