import Foundation

// Domain values use dashboard names, independent of GraphQL connection/envelope shapes.
struct GitHubRepository: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let nameWithOwner: String
    let url: URL

    var ownerLogin: String? {
        let parts = nameWithOwner.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        return String(parts[0])
    }
}

// Public profile images need no credential and never establish token ownership/access.
enum GitHubAvatar {
    static func url(for login: String?) -> URL? {
        guard let login, (1...39).contains(login.utf8.count),
              login.first != "-", login.last != "-",
              login.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45
              }) else { return nil }
        return URL(string: "https://github.com/\(login).png?size=80")
    }
}

struct GitHubPullRequest: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let number: Int
    let title: String
    let url: URL
    let repository: GitHubRepository
    // GitHub may no longer have an account for a deleted author.
    let authorLogin: String?
    let isDraft: Bool
    let createdAt: Date
    let updatedAt: Date
    // nil means not loaded/available, rather than no reviews or successful CI.
    let reviewStatus: GitHubReviewStatus?
    let latestReviews: GitHubLatestReviews?
    var checks: GitHubCheckSnapshot? = nil
    var checkStatus: GitHubCheckStatus? { checks?.status }
    let reviewRequests: [GitHubReviewRequest]?
    var headRefOid: String? = nil
    var diffStatistics: GitHubDiffStatistics? = nil

    // Revalidate at the browser boundary, including values decoded outside discovery.
    var browserURL: URL? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard url.scheme?.lowercased() == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              parts.count == 5, parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty,
              parts[3] == "pull", number > 0, parts[4] == String(number) else { return nil }
        return url
    }
}

enum GitHubReviewStatus: String, Codable, Sendable {
    case reviewRequired
    case approved
    case changesRequested
    case unknown
}

enum GitHubCheckStatus: String, Codable, Sendable {
    case pending
    case success
    case failure
    case cancelled
    case skipped
    case noChecks
    case unknown
}

enum GitHubReviewRequest: Codable, Equatable, Sendable {
    case user(login: String)
    case team(organizationLogin: String, slug: String)
}

// Supporting review information, independent of GitHub's repository review decision.
struct GitHubLatestReviews: Codable, Equatable, Sendable {
    let reviews: [GitHubPullRequestReview]
    let limitations: Set<Limitation>

    enum Limitation: String, Codable, Sendable {
        case unavailable
        case reviewerLimit
        case missingReview
        case missingIdentity
        case unknownState
    }
}

struct GitHubPullRequestReview: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let authorLogin: String?
    let state: State

    enum State: String, Codable, Sendable {
        case approved
        case changesRequested
        case commented
        case dismissed
        case pending
        case unknown
    }
}

extension GitHubPullRequest {
    func compactUpdatedAge(relativeTo now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

// A row summary never changes the authoritative GitHub decision.
struct PullRequestReviewPresentation: Equatable {
    enum Tone { case neutral, positive, caution, negative }
    let label: String
    let systemImage: String
    let tone: Tone
    let detail: String

    init(status: GitHubReviewStatus?, reviews: GitHubLatestReviews?) {
        switch status {
        case .approved:
            label = "Approved"; systemImage = "checkmark.circle.fill"; tone = .positive
        case .changesRequested:
            label = "Changes requested"; systemImage = "exclamationmark.bubble.fill"; tone = .negative
        case .reviewRequired:
            label = "Review required"; systemImage = "clock"; tone = .caution
        case .unknown, nil:
            // Count only identifiable latest submissions; deleted identities remain in the domain.
            let known = reviews?.reviews.filter { $0.authorLogin?.isEmpty == false } ?? []
            let approvals = Set(known.filter { $0.state == .approved }.compactMap { $0.authorLogin?.lowercased() }).count
            let changes = known.contains { $0.state == .changesRequested }
            let partial = reviews?.limitations.isEmpty != true
            if changes {
                label = "Changes requested by reviewer"
                systemImage = "exclamationmark.bubble"; tone = .caution
            } else if approvals > 0 {
                label = "\(partial ? "At least " : "")\(approvals) \(approvals == 1 ? "approval" : "approvals")"
                systemImage = "checkmark.bubble"; tone = .neutral
            } else if known.contains(where: { $0.state == .commented }) {
                label = "Review comments"; systemImage = "text.bubble"; tone = .neutral
            } else if reviews?.reviews.isEmpty == true && !partial {
                label = "No reviews yet"; systemImage = "bubble"; tone = .neutral
            } else {
                label = "No review decision"; systemImage = "minus.circle"; tone = .neutral
            }
        }
        let authoritative = status != nil && status != .unknown
        var explanation = authoritative ? "GitHub’s overall review decision."
            : "No authoritative overall review decision is available. This summarizes available latest reviewer activity."
        if let reviews {
            let counts = Dictionary(grouping: reviews.reviews, by: \.state)
            let activity = counts.keys.sorted { $0.rawValue < $1.rawValue }.map {
                let name: String = switch $0 {
                case .approved: "approved"
                case .changesRequested: "changes requested"
                case .commented: "commented"
                case .dismissed: "dismissed"
                case .pending: "pending"
                case .unknown: "unknown state"
                }
                return "\(counts[$0]?.count ?? 0) \(name)"
            }.joined(separator: ", ")
            if !activity.isEmpty { explanation += " Latest reviews: \(activity)." }
        }
        if reviews?.limitations.isEmpty != true { explanation += " Review details are incomplete or unavailable." }
        detail = explanation + " This does not establish merge readiness."
    }
}

extension GitHubPullRequest {
    var reviewPresentation: PullRequestReviewPresentation {
        PullRequestReviewPresentation(status: reviewStatus, reviews: latestReviews)
    }
}

// These are PR totals, never sums of downloaded files or commits.
struct GitHubDiffStatistics: Codable, Equatable, Sendable {
    let changedFiles: Int
    let additions: Int
    let deletions: Int

    init?(changedFiles: Int?, additions: Int?, deletions: Int?) {
        guard let changedFiles, let additions, let deletions,
              changedFiles >= 0, additions >= 0, deletions >= 0 else { return nil }
        self.changedFiles = changedFiles
        self.additions = additions
        self.deletions = deletions
    }

    var filesLabel: String { "\(Self.compact(changedFiles)) \(changedFiles == 1 ? "file" : "files")" }
    var additionsLabel: String { "+\(Self.compact(additions))" }
    var deletionsLabel: String { "−\(Self.compact(deletions))" }
    var accessibilityLabel: String {
        "\(changedFiles) \(changedFiles == 1 ? "file" : "files") changed, \(additions) additions, \(deletions) deletions"
    }

    private static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
    }
}

// CI evidence describes only a validated PR head; reviews and mergeability stay independent.
struct GitHubCheckSnapshot: Codable, Equatable, Sendable {
    let headOid: String?
    let status: GitHubCheckStatus
    let failingCount: Int?
    let detailsComplete: Bool
    let limitation: Limitation?

    enum Limitation: String, Codable, Sendable {
        case unavailable, headMismatch, incomplete, unknownState, conflicting
    }

    static func unavailable(headOid: String?, reason: Limitation = .unavailable) -> Self {
        Self(headOid: headOid, status: .unknown, failingCount: nil, detailsComplete: false, limitation: reason)
    }
}
