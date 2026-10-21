import Foundation

// Domain values use dashboard names, independent of GraphQL connection/envelope shapes.
struct GitHubRepository: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let nameWithOwner: String
    let url: URL
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
    let checkStatus: GitHubCheckStatus?
    let reviewRequests: [GitHubReviewRequest]?

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
