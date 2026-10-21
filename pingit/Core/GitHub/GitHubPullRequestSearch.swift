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
        let commits: Commits?
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
                checks: checkSnapshot,
                reviewRequests: reviewRequests?.pageInfo.hasNextPage == true ? nil : requests,
                headRefOid: headRefOid,
                diffStatistics: GitHubDiffStatistics(changedFiles: changedFiles, additions: additions, deletions: deletions)
            )
        }

        private var checkSnapshot: GitHubCheckSnapshot {
            guard let headRefOid, !headRefOid.isEmpty,
                  let nodes = commits?.nodes, nodes.count == 1, let commit = nodes[0]?.commit else {
                return .unavailable(headOid: headRefOid)
            }
            guard commit.oid == headRefOid else {
                return .unavailable(headOid: headRefOid, reason: .headMismatch)
            }
            return commit.statusCheckRollup?.domain(headOid: headRefOid) ?? .unavailable(headOid: headRefOid)
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

    struct Commits: Decodable, Sendable {
        let nodes: [PullRequestCommit?]?
    }

    struct PullRequestCommit: Decodable, Sendable { let commit: Commit? }
    struct Commit: Decodable, Sendable {
        let oid: String?
        let statusCheckRollup: CheckRollup?
    }

    struct CheckRollup: Decodable, Sendable {
        let state: String?
        let contexts: CheckCounts?

        func domain(headOid: String) -> GitHubCheckSnapshot {
            let counts = contexts?.normalized
            let failure = counts?.failure ?? 0
            let pending = counts?.pending ?? 0
            let complete = counts?.complete == true
            let status: GitHubCheckStatus
            // Real failures and pending evidence win over a contradictory successful rollup.
            if failure > 0 {
                status = .failure
            } else if pending > 0 {
                status = state == "FAILURE" || state == "ERROR" ? .failure : .pending
            } else if complete, counts?.cancelled ?? 0 > 0 {
                status = .cancelled
            } else if state == "FAILURE" || state == "ERROR" {
                status = .failure
            } else if state == "PENDING" || state == "EXPECTED", !complete || counts?.total != 0 {
                status = .pending
            } else if !complete {
                status = .unknown
            } else if counts?.total == 0 {
                status = .noChecks
            } else if counts?.skipped ?? 0 > 0 {
                status = .skipped
            } else {
                status = state == "SUCCESS" ? .success : .unknown
            }
            let aggregateKnown = ["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED"].contains(state ?? "")
            let contradictory = (state == "SUCCESS" && (failure > 0 || pending > 0))
                || ((state == "FAILURE" || state == "ERROR") && failure == 0 && status != .cancelled)
            let reliable = complete && aggregateKnown && !contradictory
            return GitHubCheckSnapshot(headOid: headOid, status: status,
                failingCount: reliable && status == .failure ? failure : nil,
                detailsComplete: reliable,
                limitation: reliable ? nil : aggregateKnown ? .incomplete : .unknownState)
        }
    }

    struct CheckCounts: Decodable, Sendable {
        let totalCount: Int?
        let checkRunCount: Int?
        let statusContextCount: Int?
        let checkRunCountsByState: [StateCount]?
        let statusContextCountsByState: [StateCount]?

        struct StateCount: Decodable, Sendable { let state: String; let count: Int }
        struct Normalized {
            var total = 0
            var failure = 0
            var pending = 0
            var cancelled = 0
            var skipped = 0
            var complete = true
        }

        var normalized: Normalized {
            var result = Normalized()
            let failures: Set<String> = ["FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"]
            let pending: Set<String> = ["PENDING", "EXPECTED", "QUEUED", "IN_PROGRESS", "WAITING", "REQUESTED"]
            for (entries, expected, isRun) in [(checkRunCountsByState, checkRunCount, true),
                                              (statusContextCountsByState, statusContextCount, false)] {
                guard let entries, entries.count <= 32, let expected, (0...Int(Int32.max)).contains(expected) else {
                    result.complete = false; continue
                }
                var seen: Set<String> = []
                var sum = 0
                for entry in entries {
                    guard (0...Int(Int32.max)).contains(entry.count), seen.insert(entry.state).inserted else {
                        result.complete = false; continue
                    }
                    sum += entry.count
                    guard entry.count > 0 else { continue }
                    let allowed: Set<String> = isRun
                        ? ["SUCCESS", "FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED", "PENDING", "QUEUED",
                           "IN_PROGRESS", "WAITING", "CANCELLED", "SKIPPED", "NEUTRAL", "COMPLETED", "STALE"]
                        : ["SUCCESS", "FAILURE", "ERROR", "PENDING", "EXPECTED"]
                    guard allowed.contains(entry.state) else { result.complete = false; continue }
                    if failures.contains(entry.state) { result.failure += entry.count }
                    else if pending.contains(entry.state) { result.pending += entry.count }
                    else if entry.state == "CANCELLED" { result.cancelled += entry.count }
                    else if entry.state == "SKIPPED" || entry.state == "NEUTRAL" { result.skipped += entry.count }
                    else if entry.state != "SUCCESS" { result.complete = false }
                }
                if sum != expected { result.complete = false }
                result.total += expected
            }
            if totalCount != result.total { result.complete = false }
            return result
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

    // Recover only errors confined to a PR's CI subtree. Every affected rollup is
    // discarded, including an apparently successful aggregate beside a denied counter.
    static func recoverUnavailableChecks(from data: Data) -> Self? {
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let errors = envelope["errors"] as? [[String: Any]], !errors.isEmpty,
              var root = envelope["data"] as? [String: Any],
              var search = root["search"] as? [String: Any], var nodes = search["nodes"] as? [Any] else { return nil }
        for error in errors {
            guard let path = error["path"] as? [Any], path.count >= 8,
                  path[0] as? String == "search", path[1] as? String == "nodes",
                  let index = path[2] as? Int, nodes.indices.contains(index),
                  path[3] as? String == "commits", path[4] as? String == "nodes", path[5] as? Int == 0,
                  path[6] as? String == "commit", path[7] as? String == "statusCheckRollup",
                  var node = nodes[index] as? [String: Any] else { return nil }
            // Dropping the whole CI connection also handles GraphQL null bubbling safely.
            node["commits"] = NSNull()
            nodes[index] = node
        }
        search["nodes"] = nodes
        root["search"] = search
        guard let sanitized = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: sanitized)
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
            commits(last: 1) {
              nodes {
                commit {
                  oid
                  statusCheckRollup {
                    state
                    contexts(first: 1) {
                      totalCount checkRunCount statusContextCount
                      checkRunCountsByState { state count }
                      statusContextCountsByState { state count }
                    }
                  }
                }
              }
            }
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
