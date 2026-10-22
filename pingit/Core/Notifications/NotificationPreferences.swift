import Foundation
import Observation

@MainActor
@Observable
final class NotificationPreferences {
    var enabled: Bool { didSet { save(enabled, key: "enabled", previous: oldValue) } }
    var reviewRequested: Bool { didSet { save(reviewRequested, key: "reviewRequested", previous: oldValue) } }
    var reviewRequestRemoved: Bool { didSet { save(reviewRequestRemoved, key: "reviewRequestRemoved", previous: oldValue) } }
    var approved: Bool { didSet { save(approved, key: "approved", previous: oldValue) } }
    var changesRequested: Bool { didSet { save(changesRequested, key: "changesRequested", previous: oldValue) } }
    var readyForReview: Bool { didSet { save(readyForReview, key: "readyForReview", previous: oldValue) } }
    var newPRComments: Bool { didSet { save(newPRComments, key: "newPRComments", previous: oldValue) } }
    var reviewThreadReplies: Bool { didSet { save(reviewThreadReplies, key: "reviewThreadReplies", previous: oldValue) } }
    var botComments: Bool { didSet { save(botComments, key: "botComments", previous: oldValue) } }
    var sound: Bool { didSet { save(sound, key: "sound", previous: oldValue) } }

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored var onChange: (() -> Void)?

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        enabled = defaults?.object(forKey: "notifications.enabled") as? Bool ?? false
        reviewRequested = defaults?.object(forKey: "notifications.reviewRequested") as? Bool ?? true
        reviewRequestRemoved = defaults?.object(forKey: "notifications.reviewRequestRemoved") as? Bool ?? false
        approved = defaults?.object(forKey: "notifications.approved") as? Bool ?? true
        changesRequested = defaults?.object(forKey: "notifications.changesRequested") as? Bool ?? true
        readyForReview = defaults?.object(forKey: "notifications.readyForReview") as? Bool ?? false
        newPRComments = defaults?.object(forKey: "notifications.newPRComments") as? Bool ?? true
        reviewThreadReplies = defaults?.object(forKey: "notifications.reviewThreadReplies") as? Bool ?? true
        botComments = defaults?.object(forKey: "notifications.botComments") as? Bool ?? false
        sound = defaults?.object(forKey: "notifications.sound") as? Bool ?? false
    }

    func allows(_ kind: PullRequestChangeEvent.Kind) -> Bool {
        guard enabled else { return false }
        switch kind {
        case .reviewRequested: return reviewRequested
        case .reviewRequestRemoved: return reviewRequestRemoved
        case .approved: return approved
        case .changesRequested: return changesRequested
        case .readyForReview: return readyForReview
        case .newPRComment, .newInlineReviewComment: return newPRComments
        case .newReviewThreadReply: return reviewThreadReplies
        }
    }

    private func save(_ value: Bool, key: String, previous: Bool) {
        guard value != previous else { return }
        defaults?.set(value, forKey: "notifications.\(key)")
        onChange?()
    }
}

enum NotificationPermission: Equatable, Sendable {
    case unknown, notDetermined, denied, authorized, provisional, unavailable

    var allowsDelivery: Bool { self == .authorized || self == .provisional }
    var label: String {
        switch self {
        case .unknown: "Checking permission…"
        case .notDetermined: "Not requested"
        case .denied: "Denied — allow pingit in macOS System Settings → Notifications."
        case .authorized: "Authorized"
        case .provisional: "Quiet delivery authorized"
        case .unavailable: "Unavailable"
        }
    }
}
