import Foundation

// Transport-only shapes. Required fields decode strictly; nullable GitHub actors stay optional.
struct GitHubPullRequestSearchResponse: Decodable, Sendable {
    let viewer: Actor
    let search: Search

    struct Actor: Decodable, Sendable { let login: String }

    struct PageInfo: Decodable, Sendable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct Search: Decodable, Sendable {
        let issueCount: Int
        let nodes: [PullRequest?]
        let pageInfo: PageInfo
    }

    struct PullRequest: Decodable, Sendable {
        let __typename: String
        let id: String
        let number: Int
        let title: String
        let url: URL
        let repository: Repository
        let author: Actor?
        let state: State
        let isDraft: Bool
        let createdAt: String
        let updatedAt: String
        let headRefOid: String?
        let changedFiles: Int?
        let additions: Int?
        let deletions: Int?
        let reviewDecision: String?
        let latestReviews: LatestReviews?
        let reviewRequests: ReviewRequests?

        enum State: String, Decodable, Sendable { case open = "OPEN", closed = "CLOSED", merged = "MERGED" }

        func domain() throws -> GitHubPullRequest {
            guard __typename == "PullRequest", !id.isEmpty, number > 0,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !repository.id.isEmpty, !repository.nameWithOwner.isEmpty,
                  Self.isGitHubURL(url), Self.isGitHubURL(repository.url),
                  author?.login.isEmpty != true else {
                throw GitHubAPIError.unexpectedResponse
            }
            let requests = try reviewRequests?.nodes.compactMap { try $0?.requestedReviewer?.domain() }
            return GitHubPullRequest(
                id: id, number: number, title: title, url: url,
                repository: GitHubRepository(id: repository.id, nameWithOwner: repository.nameWithOwner, url: repository.url),
                authorLogin: author?.login, isDraft: isDraft,
                createdAt: try Self.date(createdAt), updatedAt: try Self.date(updatedAt),
                reviewStatus: overallReviewStatus,
                latestReviews: latestReviews?.domain() ?? GitHubLatestReviews(reviews: [], limitations: [.unavailable]),
                checkStatus: nil,
                reviewRequests: reviewRequests?.pageInfo.hasNextPage == true ? nil : requests,
                headRefOid: headRefOid,
                diffStatistics: GitHubDiffStatistics(changedFiles: changedFiles, additions: additions, deletions: deletions)
            )
        }

        private var overallReviewStatus: GitHubReviewStatus {
            switch reviewDecision {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "REVIEW_REQUIRED": .reviewRequired
            default: .unknown
            }
        }

        private static func date(_ value: String) throws -> Date {
            if let date = try? Date.ISO8601FormatStyle().parse(value) { return date }
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value) { return date }
            throw GitHubAPIError.unexpectedResponse
        }

        private static func isGitHubURL(_ url: URL) -> Bool {
            url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
                && url.user == nil && url.password == nil && url.port == nil
        }
    }

    struct Repository: Decodable, Sendable {
        let id: String
        let nameWithOwner: String
        let url: URL
    }

    struct LatestReviews: Decodable, Sendable {
        let nodes: [Review?]?
        let pageInfo: PageInfo

        func domain() -> GitHubLatestReviews {
            var limitations: Set<GitHubLatestReviews.Limitation> = []
            if pageInfo.hasNextPage { limitations.insert(.reviewerLimit) }
            guard let nodes else {
                limitations.insert(.unavailable)
                return GitHubLatestReviews(reviews: [], limitations: limitations)
            }
            // GitHub selects the latest non-pending review per user, excluding superseded submissions.
            let reviews = nodes.compactMap { node -> GitHubPullRequestReview? in
                guard let node else { limitations.insert(.missingReview); return nil }
                let login = node.author?.login
                let identity = login?.isEmpty == false ? login : nil
                if identity == nil { limitations.insert(.missingIdentity) }
                let state: GitHubPullRequestReview.State = switch node.state {
                case "APPROVED": .approved
                case "CHANGES_REQUESTED": .changesRequested
                case "COMMENTED": .commented
                case "DISMISSED": .dismissed
                case "PENDING": .pending
                default: .unknown
                }
                if state == .unknown { limitations.insert(.unknownState) }
                return GitHubPullRequestReview(id: node.id, authorLogin: identity, state: state)
            }
            return GitHubLatestReviews(reviews: reviews, limitations: limitations)
        }
    }

    struct Review: Decodable, Sendable {
        let id: String
        let author: Actor?
        let state: String?
    }

    struct ReviewRequests: Decodable, Sendable {
        let nodes: [ReviewRequest?]
        let pageInfo: PageInfo

        func contains(login: String) -> Bool {
            nodes.contains { request in
                request?.requestedReviewer?.__typename == "User"
                    && request?.requestedReviewer?.login?.caseInsensitiveCompare(login) == .orderedSame
            }
        }
    }

    struct ReviewRequest: Decodable, Sendable { let requestedReviewer: Reviewer? }

    struct Reviewer: Decodable, Sendable {
        let __typename: String
        let login: String?
        let slug: String?
        let organization: Actor?

        func domain() throws -> GitHubReviewRequest? {
            switch __typename {
            case "User":
                guard let login, !login.isEmpty else { throw GitHubAPIError.unexpectedResponse }
                return .user(login: login)
            case "Team":
                guard let slug, !slug.isEmpty, let organization, !organization.login.isEmpty else {
                    throw GitHubAPIError.unexpectedResponse
                }
                return .team(organizationLogin: organization.login, slug: slug)
            default:
                // A deleted/replaced actor cannot represent the currently authenticated user.
                return nil
            }
        }
    }

    static let query = """
    query PullRequestDiscovery($query: String!, $first: Int!, $after: String, $includeReviewRequests: Boolean!) {
      viewer { login }
      search(query: $query, type: ISSUE, first: $first, after: $after) {
        issueCount
        pageInfo { hasNextPage endCursor }
        nodes {
          __typename
          ... on PullRequest {
            id number title url state isDraft createdAt updatedAt
            headRefOid changedFiles additions deletions
            reviewDecision
            latestReviews(first: 50) {
              pageInfo { hasNextPage endCursor }
              nodes { id state author { login } }
            }
            author { login }
            repository { id nameWithOwner url }
            reviewRequests(first: 100) @include(if: $includeReviewRequests) {
              pageInfo { hasNextPage endCursor }
              nodes {
                requestedReviewer {
                  __typename
                  ... on User { login }
                  ... on Team { slug organization { login } }
                }
              }
            }
          }
        }
      }
    }
    """
}
