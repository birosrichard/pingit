import Foundation
import Observation

@MainActor
@Observable
final class NotificationPreferences {
    var enabled: Bool { didSet { save(enabled, key: "enabled") } }
    var reviewRequested: Bool { didSet { save(reviewRequested, key: "reviewRequested") } }
    var reviewRequestRemoved: Bool { didSet { save(reviewRequestRemoved, key: "reviewRequestRemoved") } }
    var approved: Bool { didSet { save(approved, key: "approved") } }
    var changesRequested: Bool { didSet { save(changesRequested, key: "changesRequested") } }
    var readyForReview: Bool { didSet { save(readyForReview, key: "readyForReview") } }
    var sound: Bool { didSet { save(sound, key: "sound") } }

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
        }
    }

    private func save(_ value: Bool, key: String) {
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
