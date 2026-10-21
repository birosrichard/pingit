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
    let checkStatus: GitHubCheckStatus?
    let reviewRequests: [GitHubReviewRequest]?
}

enum GitHubReviewStatus: String, Codable, Sendable {
    case reviewRequired
    case approved
    case changesRequested
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
