import CryptoKit
import Foundation

struct PullRequestChangeEvent: Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case reviewRequested, reviewRequestRemoved, approved, changesRequested, readyForReview
        case newPRComment, newInlineReviewComment, newReviewThreadReply
        case prMerged, prClosed, prReopened
    }
    enum Signal: String, Sendable { case membership, decision, reviewer, draft, conversation, lifecycle }
    let id: String
    let kind: Kind
    let pullRequestID: String
    let repository: GitHubRepository
    let number: Int
    // Removal after restart may have no current title. Titles are never persisted.
    let title: String?
    let url: URL
    let observedAt: Date
    let actorLogin: String?
    let signal: Signal
    let previousState: String
    let currentState: String
    let sourceIDs: [String]
    var actorIsBot = false
    var relatedReviewIDs: [String] = []
    var threadID: String? = nil
}

// Disk values deliberately omit repository names, titles, URLs and reviewer logins.
struct PullRequestChangeSnapshot: Codable, Equatable, Sendable {
    static let schemaVersion = 3
    var version = schemaVersion
    var identity: String
    var epoch = UUID()
    var revision: UInt64 = 0
    var sources: [String: Source] = [:]
    var rebasingRepositories: [String] = []
    var conversationScopes: [String]? = nil
    var lifecycleScopes: [String]? = nil
    var lifecycles: [String: Lifecycle]? = nil

    struct Source: Codable, Equatable, Sendable {
        var authored: [String: PullRequest]?
        var requested: [String: PullRequest]?
        var conversations: [String: Conversation]? = nil
    }
    struct PullRequest: Codable, Equatable, Sendable {
        let repositoryID: String
        let number: Int
        let updatedAt: Date
        let isDraft: Bool
        let decision: GitHubReviewStatus?
        var reviewers: [String: Review]?
        var reviewsComplete: Bool

        init(_ pr: GitHubPullRequest) {
            repositoryID = pr.repository.id
            number = pr.number
            updatedAt = pr.updatedAt
            isDraft = pr.isDraft
            decision = pr.reviewStatus
            if let details = pr.latestReviews, details.limitations.isEmpty,
               details.reviews.allSatisfy({ $0.authorLogin?.isEmpty == false && $0.state != .unknown && $0.state != .pending }),
               Set(details.reviews.compactMap { $0.authorLogin?.lowercased() }).count == details.reviews.count {
                reviewers = Dictionary(uniqueKeysWithValues: details.reviews.map {
                    (changeDigest($0.authorLogin!.lowercased()), Review(id: $0.id, state: $0.state))
                })
            } else { reviewers = nil }
            reviewsComplete = reviewers != nil
        }
    }
    struct Review: Codable, Equatable, Sendable {
        let id: String
        let state: GitHubPullRequestReview.State
    }
}

func changeDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct PullRequestChangeScope: Equatable, Sendable {
    let id: String
    let identity: String

    init?(_ row: GitHubTokenConnection) {
        guard let account = row.account else { return nil }
        id = row.storageAccount
        identity = changeDigest(account.id.map { "id:\($0)" } ?? "login:\(account.login.lowercased())")
    }
}

// Only results actually received in this flight enter detection; cached dashboard rows never do.
struct PullRequestChangeInput: Sendable {
    let sequence: UInt64
    let scopes: [PullRequestChangeScope]
    let results: [String: Sections]
    let observedAt: Date
    struct Sections: Sendable {
        var authored: GitHubPullRequestDiscoveryResult?
        var requested: GitHubPullRequestDiscoveryResult?
        var conversations: GitHubConversationResult? = nil
        var lifecycles: GitHubLifecycleResult? = nil
    }
}
