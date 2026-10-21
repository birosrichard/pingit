import Foundation

// The default row intentionally projects only identity, review context and diff totals.
// CI remains in the domain and transport for a future authentication strategy.
struct PullRequestRowPresentation: Equatable {
    let title: String
    let repositoryLabel: String
    let updatedAt: Date
    let avatarOwner: String?
    let authorLabel: String?
    let review: PullRequestReviewPresentation?
    let diff: GitHubDiffStatistics?
    let browserURL: URL?
    let accessibilityLabel: String
    let help: String

    init(pr: GitHubPullRequest, inbox: PullRequestInbox) {
        title = pr.title
        repositoryLabel = "\(pr.repository.nameWithOwner) #\(pr.number)"
        updatedAt = pr.updatedAt
        avatarOwner = pr.repository.ownerLogin
        authorLabel = inbox == .review ? pr.authorLogin.map { "@\($0)" } ?? "Author unavailable" : nil
        review = inbox == .review ? nil : pr.reviewPresentation
        diff = pr.diffStatistics
        browserURL = pr.browserURL
        let context = authorLabel ?? review?.label ?? ""
        let detail = review?.detail ?? "Pull request author: \(pr.authorLogin ?? "unavailable")."
        let diffDescription = diff?.accessibilityLabel ?? "Diff statistics unavailable"
        accessibilityLabel = "\(pr.isDraft ? "Draft pull request" : "Pull request") \(pr.number). \(title). \(repositoryLabel). \(context). \(detail) \(diffDescription)."
        help = "\(title)\n\(repositoryLabel)\n\(detail)\n\(diffDescription)\n\(browserURL == nil ? "GitHub link unavailable" : "Open on GitHub")"
    }

    func compactUpdatedAge(relativeTo now: Date) -> String {
        GitHubPullRequest.compactAge(updatedAt: updatedAt, relativeTo: now)
    }
}

struct PullRequestEmptyPresentation: Equatable {
    let title: String
    let message: String
    let systemImage: String
    let isLoading: Bool
    let isFailure: Bool

    init(inbox: PullRequestInbox, phase: PullRequestSectionState.Phase) {
        isLoading = phase == .idle || phase == .loading
        isFailure = phase == .failed
        if isLoading {
            title = "Loading pull requests…"
            message = "Fetching the repositories visible to your tokens."
            systemImage = "arrow.clockwise"
        } else if isFailure {
            title = "Couldn’t update this inbox"
            message = "Refresh to retry, or open update details below."
            systemImage = "exclamationmark.triangle"
        } else {
            title = inbox == .review ? "All caught up" : inbox == .drafts ? "No drafts" : "No open pull requests"
            message = inbox == .review ? "No direct requests in the repositories visible to your tokens."
                : "Nothing here in the repositories visible to your tokens."
            systemImage = inbox == .review ? "checkmark.circle" : "tray"
        }
    }
}

// A small shared spacing scale for the native popover, not a separate theme system.
enum DashboardLayout {
    static let width: CGFloat = 440
    static let horizontalInset: CGFloat = 20
    static let listInset: CGFloat = 8
    static let rowInset: CGFloat = 12
    static let avatarSize: CGFloat = 36
    static let avatarSpacing: CGFloat = 12

    static func listHeight(rowCount: Int, availableScreenHeight: CGFloat, contentHeight: CGFloat? = nil) -> CGFloat {
        let initialHeight = max(144, CGFloat(max(0, rowCount)) * 108)
        return min(420, max(1, availableScreenHeight - 260), max(1, contentHeight ?? initialHeight))
    }
}

extension PullRequestInbox {
    var shortTitle: String {
        switch self {
        case .review: "Review"
        case .authored: "My PRs"
        case .drafts: "Drafts"
        }
    }

    var contextTitle: String {
        switch self {
        case .review: "Requested from you"
        case .authored: "Open pull requests"
        case .drafts: "Work in progress"
        }
    }
}
