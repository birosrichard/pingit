import Foundation

// No scores, time thresholds, comment inference, persistence or UI dependencies.
enum PullRequestAttention: Equatable, Sendable {
    case needsAttention(PullRequestAttentionReason)
    case waitingOnOthers
    case workInProgress
    case unknown(Uncertainty)

    enum Uncertainty: Equatable, Sendable {
        case previous, incomplete, conflicting, missingMetadata
    }

    enum Coverage: Equatable, Sendable {
        case current, previous, incomplete, conflicting
    }

    var reason: PullRequestAttentionReason? {
        if case .needsAttention(let reason) = self { return reason }
        return nil
    }

    static func classify(_ pr: GitHubPullRequest, viewerLogin: String?, coverage: Coverage) -> Self {
        // Coverage gates every claim, including drafts. A retained row is not a new observation.
        switch coverage {
        case .previous: return .unknown(.previous)
        case .incomplete: return .unknown(.incomplete)
        case .conflicting: return .unknown(.conflicting)
        case .current: break
        }
        guard let viewerLogin, !viewerLogin.isEmpty, let author = pr.authorLogin else {
            return .unknown(.missingMetadata)
        }
        let authored = author.caseInsensitiveCompare(viewerLogin) == .orderedSame
        if pr.isDraft { return authored ? .workInProgress : .unknown(.missingMetadata) }
        if authored {
            // Individual submissions cannot substitute for GitHub's overall decision.
            switch pr.reviewStatus {
            case .changesRequested: return .needsAttention(.changesRequested)
            case .reviewRequired, .approved: return .waitingOnOthers
            case nil, .unknown: return .unknown(.missingMetadata)
            }
        }
        guard let requests = pr.reviewRequests else { return .unknown(.missingMetadata) }
        if requests.contains(where: {
            if case .user(let login) = $0 { return login.caseInsensitiveCompare(viewerLogin) == .orderedSame }
            return false
        }) { return .needsAttention(.reviewRequested) }
        return .waitingOnOthers
    }

    var label: String {
        switch self {
        case .needsAttention: "Needs attention"
        case .waitingOnOthers: "Waiting on others"
        case .workInProgress: "Work in progress"
        case .unknown(.previous): "Previous data"
        case .unknown: "Attention unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .needsAttention(let reason): reason.systemImage
        case .waitingOnOthers: "clock"
        case .workInProgress: "pencil.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var explanation: String {
        switch self {
        case .needsAttention(let reason): reason.explanation
        case .waitingOnOthers:
            "No supported action is identified for you. An approval does not establish merge readiness."
        case .workInProgress:
            "Your pull request is a draft; it is not an active review request."
        case .unknown(.previous):
            "Previous snapshot. Refresh is pending, in progress, or failed; the next action is unverified."
        case .unknown(.incomplete):
            "Discovery is incomplete. The next action cannot be determined reliably."
        case .unknown(.conflicting):
            "Token observations disagree. The next action cannot be determined reliably."
        case .unknown(.missingMetadata):
            "Authoritative review or identity data is unavailable. The next action is unknown."
        }
    }

    var accessibilityLabel: String { "\(label). \(explanation)" }
}

enum PullRequestAttentionReason: String, CaseIterable, Identifiable, Sendable {
    case reviewRequested = "review-requested"
    case changesRequested = "changes-requested"

    enum Emphasis: Sendable { case accent }
    var id: String { rawValue }
    var emphasis: Emphasis { .accent }
    var label: String {
        switch self {
        case .reviewRequested: "Review requested from you"
        case .changesRequested: "Changes requested on your PR"
        }
    }
    var systemImage: String {
        switch self {
        case .reviewRequested: "person.crop.circle.badge.checkmark"
        case .changesRequested: "bubble.left.and.text.bubble.right"
        }
    }
    var explanation: String {
        switch self {
        case .reviewRequested: "An active direct GitHub review request is assigned to you."
        case .changesRequested: "GitHub’s authoritative overall review decision requests changes on your pull request."
        }
    }
    var accessibilityLabel: String { "\(label). \(explanation)" }
}
