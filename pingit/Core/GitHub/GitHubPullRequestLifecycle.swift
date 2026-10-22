import Foundation

// Authoritative node state is independent of open-search membership and dashboard rows.
enum GitHubPullRequestState: String, Codable, Sendable {
    case open = "OPEN", closed = "CLOSED", merged = "MERGED"
}

struct GitHubLifecycleObservation: Sendable {
    let id: String
    let repository: GitHubRepository
    let number: Int
    let url: URL
    let state: GitHubPullRequestState
    let isDraft: Bool
    let updatedAt: Date
    let closedAt: Date?
    let mergedAt: Date?
    let verifiedAt: Date
}

struct GitHubLifecyclePlan: Sendable {
    static let maximumPullRequests = 100
    static let batchSize = 20
    static let maximumBatches = 5
    static let closedRetention: TimeInterval = 7 * 86_400
    static let unverifiedRetention: TimeInterval = 30 * 86_400
    struct Batch: Sendable {
        let scopeID: String
        var ids: [String]
    }
    var batches: [Batch] = []
    var limited = false
}

struct GitHubLifecycleResult: Sendable {
    var observations: [String: GitHubLifecycleObservation] = [:]
    var limited = false
    var error: GitHubAPIError?
}

struct GitHubLifecycleDiscovery: Sendable {
    let client: GitHubClient

    func fetch(ids: [String], account: GitHubAccount, token: String,
               now: @Sendable () -> Date = Date.init) async -> GitHubLifecycleResult {
        guard !ids.isEmpty else { return .init() }
        guard ids.count <= GitHubLifecyclePlan.batchSize, Set(ids).count == ids.count else { return .init(limited: true) }
        do {
            try Task.checkCancellation()
            let started = now()
            let response: Response = try await client.graphQL(query: Self.query, variables: Variables(ids: ids), token: token)
            try Task.checkCancellation()
            guard response.viewer.login.caseInsensitiveCompare(account.login) == .orderedSame,
                  account.id.map({ $0 == response.viewer.databaseId }) ?? true else {
                throw GitHubDiscoveryError.accountMismatch
            }
            let received = response.nodes.compactMap { $0?.id }
            guard response.nodes.count == ids.count, Set(received).count == received.count,
                  Set(received).isSubset(of: Set(ids)) else { throw GitHubAPIError.unexpectedResponse }
            var result = GitHubLifecycleResult(limited: received.count != ids.count)
            // Validate the entire batch before publishing any of its nodes. Partial GraphQL
            // errors are already rejected by GitHubClient; a null node proves no state.
            for node in response.nodes.compactMap({ $0 }) {
                guard node.__typename == "PullRequest", !node.id.isEmpty, node.number > 0,
                      !node.repository.id.isEmpty,
                      node.author?.login.caseInsensitiveCompare(account.login) == .orderedSame,
                      let url = GitHubNotificationURL.validate(node.url.absoluteString), url.fragment == nil,
                      url.path == "/\(node.repository.nameWithOwner)/pull/\(node.number)" else {
                    throw GitHubAPIError.unexpectedResponse
                }
                let updated = try Self.date(node.updatedAt)
                let closed = try node.closedAt.map(Self.date)
                let merged = try node.mergedAt.map(Self.date)
                guard (node.state == .merged ? merged != nil && closed != nil : merged == nil),
                      node.state != .closed || closed != nil,
                      node.state != .open || closed == nil,
                      closed.map({ $0 <= updated }) ?? true,
                      merged.map({ $0 <= updated }) ?? true else { throw GitHubAPIError.unexpectedResponse }
                result.observations[node.id] = .init(id: node.id, repository: node.repository, number: node.number,
                    url: url, state: node.state, isDraft: node.isDraft, updatedAt: updated,
                    closedAt: closed, mergedAt: merged, verifiedAt: started)
            }
            // Even the final low-budget response restricts subsequent batches/shared refreshes.
            if response.rateLimit.remaining < 50 {
                result.error = .rateLimitedUntil(try Self.date(response.rateLimit.resetAt))
            }
            return result
        } catch is CancellationError { return .init(limited: true) }
        catch { return .init(limited: true, error: error as? GitHubAPIError ?? .unexpectedResponse) }
    }

    private static func date(_ string: String) throws -> Date {
        if let value = try? Date.ISO8601FormatStyle().parse(string) { return value }
        if let value = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return value }
        throw GitHubAPIError.unexpectedResponse
    }
    private struct Variables: Encodable, Sendable { let ids: [String] }
    private struct Actor: Decodable, Sendable { let login: String; let databaseId: Int? }
    private struct RateLimit: Decodable, Sendable { let remaining: Int; let resetAt: String }
    private struct Response: Decodable, Sendable {
        let viewer: Actor
        let nodes: [Node?]
        let rateLimit: RateLimit
    }
    private struct Node: Decodable, Sendable {
        let __typename: String
        let id: String
        let number: Int
        let url: URL
        let repository: GitHubRepository
        let author: Actor?
        let state: GitHubPullRequestState
        let isDraft: Bool
        let updatedAt: String
        let closedAt: String?
        let mergedAt: String?
    }
    static let query = """
    query PullRequestLifecycle($ids: [ID!]!) {
      viewer { databaseId login }
      rateLimit { remaining resetAt }
      nodes(ids: $ids) { __typename ... on PullRequest {
        id number url state isDraft updatedAt closedAt mergedAt
        author { login }
        repository { id nameWithOwner url }
      } }
    }
    """
}
