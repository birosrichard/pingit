import Foundation

// Bodies exist only in the transport normalization scope. These values contain no text.
struct GitHubConversationComment: Equatable, Sendable {
    let id: String
    let kind: PullRequestChangeEvent.Kind
    let publishedAt: Date
    let url: URL
    let actorLogin: String
    let isBot: Bool
    let relevant: Bool
    let reviewID: String?
    var threadID: String? = nil
}

struct GitHubConversationObservation: Sendable {
    let id: String
    let repository: GitHubRepository
    let number: Int
    let fingerprint: String
    let verifiedAt: Date
    let comments: [GitHubConversationComment]?
    let lastRequestedAt: Date?
    // nil comments are only comparable when a complete probe matches this fingerprint.
}

struct GitHubConversationPlan: Sendable {
    static let maximumPullRequests = 40
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    struct Target: Sendable {
        let id: String
        let authored: Bool
        let lastRequestedAt: Date?
        let fingerprint: String?
    }
    var targets: [Target] = []
}

struct GitHubConversationResult: Sendable {
    var observations: [String: GitHubConversationObservation] = [:]
    var attemptedIDs: [String] = []
    var limited = false
    var error: GitHubAPIError?
}

extension PullRequestChangeSnapshot {
    struct Conversation: Codable, Equatable, Sendable {
        let repositoryID: String
        let number: Int
        var fingerprint: String
        var verifiedAt: Date
        var commentIDs: [String]
        var comparable: Bool
        var lastRequestedAt: Date?
    }
}

struct GitHubConversationDiscovery: Sendable {
    static let batchSize = 5
    static let connectionLimit = 50
    let client: GitHubClient

    init(client: GitHubClient = GitHubClient()) { self.client = client }

    func fetch(plan: GitHubConversationPlan, account: GitHubAccount, token: String,
               now: @Sendable () -> Date = Date.init) async -> GitHubConversationResult {
        var result = GitHubConversationResult()
        let targets = Array(plan.targets.prefix(GitHubConversationPlan.maximumPullRequests))
        result.attemptedIDs = targets.map(\.id)
        result.limited = plan.targets.count > targets.count
        guard !targets.isEmpty else { return result }
        do {
            for offset in stride(from: 0, to: targets.count, by: Self.batchSize) {
                try Task.checkCancellation()
                let batch = Array(targets[offset..<min(offset + Self.batchSize, targets.count)])
                let started = now()
                let probe: Response = try await client.graphQL(query: Self.probeQuery,
                    variables: Variables(ids: batch.map(\.id)), token: token)
                try probe.validate(account: account, ids: batch.map(\.id))
                var changed: [GitHubConversationPlan.Target] = []
                for target in batch {
                    guard let node = probe.nodes.compactMap({ $0 }).first(where: { $0.id == target.id }),
                          node.state == "OPEN", let fingerprint = try node.fingerprint() else {
                        result.limited = true
                        continue
                    }
                    if target.fingerprint == fingerprint {
                        result.observations[target.id] = try node.observation(target: target,
                            fingerprint: fingerprint, at: started, comments: nil)
                    } else { changed.append(target) }
                }
                if !changed.isEmpty {
                    try probe.rateLimit.check()
                    let detailStart = now()
                    let details: Response = try await client.graphQL(query: Self.detailQuery,
                        variables: Variables(ids: changed.map(\.id)), token: token)
                    try details.validate(account: account, ids: changed.map(\.id))
                    for target in changed {
                        guard let node = details.nodes.compactMap({ $0 }).first(where: { $0.id == target.id }),
                              node.state == "OPEN", let fingerprint = try node.fingerprint(),
                              let comments = try node.normalizedComments(viewer: details.viewer, authored: target.authored) else {
                            result.limited = true
                            continue
                        }
                        result.observations[target.id] = try node.observation(target: target,
                            fingerprint: fingerprint, at: detailStart, comments: comments)
                    }
                    if offset + Self.batchSize < targets.count { try details.rateLimit.check() }
                } else if offset + Self.batchSize < targets.count { try probe.rateLimit.check() }
            }
        } catch is CancellationError { return .init(attemptedIDs: targets.map(\.id)) }
        catch {
            result.error = error as? GitHubAPIError ?? .unexpectedResponse
            // Retain successful independent batches, with explicit missing observations elsewhere.
        }
        return result
    }

    private struct Variables: Encodable, Sendable { let ids: [String] }
    private struct Response: Decodable, Sendable {
        let viewer: Actor
        let nodes: [PullRequest?]
        let rateLimit: RateLimit
        func validate(account: GitHubAccount, ids: [String]) throws {
            guard viewer.login.caseInsensitiveCompare(account.login) == .orderedSame,
                  account.id.map({ String($0) == viewer.databaseId.map(String.init) }) ?? true else {
                throw GitHubDiscoveryError.accountMismatch
            }
            let received = nodes.compactMap { $0?.id }
            guard nodes.count == ids.count, Set(received).count == received.count,
                  Set(received).isSubset(of: Set(ids)) else { throw GitHubAPIError.unexpectedResponse }
        }
    }
    private struct RateLimit: Decodable, Sendable {
        let remaining: Int
        let resetAt: String
        func check() throws {
            if remaining < 50 { throw GitHubAPIError.rateLimitedUntil(try date(resetAt)) }
        }
    }
    private struct Actor: Decodable, Sendable {
        let __typename: String?
        let id: String?
        let databaseId: Int?
        let login: String
        func isViewer(_ viewer: Actor) -> Bool {
            (id != nil && id == viewer.id) || login.caseInsensitiveCompare(viewer.login) == .orderedSame
        }
    }
    private struct PageInfo: Decodable, Sendable { let hasNextPage: Bool }
    private struct Comments: Decodable, Sendable {
        let totalCount: Int
        let nodes: [Comment?]
        let pageInfo: PageInfo?
        var complete: Bool {
            pageInfo?.hasNextPage == false && totalCount >= 0 && totalCount <= connectionLimit
                && nodes.count == totalCount && nodes.allSatisfy { $0 != nil }
        }
    }
    private struct Comment: Decodable, Sendable {
        let id: String
        let publishedAt: String?
        let createdAt: String?
        let url: URL?
        let body: String?
        let author: Actor?
        let state: String?
        let replyTo: Reference?
        let pullRequestReview: Review?
    }
    private struct Reference: Decodable, Sendable { let id: String }
    private struct Review: Decodable, Sendable { let id: String; let state: String; let submittedAt: String? }
    private struct Thread: Decodable, Sendable { let id: String; let comments: Comments }
    private struct Threads: Decodable, Sendable {
        let totalCount: Int
        let nodes: [Thread?]
        let pageInfo: PageInfo
        var complete: Bool {
            !pageInfo.hasNextPage && totalCount >= 0 && totalCount <= connectionLimit
                && nodes.count == totalCount && nodes.allSatisfy { $0 != nil }
        }
    }
    private struct PullRequest: Decodable, Sendable {
        let id: String
        let number: Int
        let state: String
        let updatedAt: String
        let repository: GitHubRepository
        let comments: Comments
        let reviewThreads: Threads

        func fingerprint() throws -> String? {
            guard reviewThreads.complete, comments.totalCount >= 0, comments.totalCount <= connectionLimit,
                  comments.nodes.allSatisfy({ $0 != nil }) else { return nil }
            let threads = reviewThreads.nodes.compactMap { $0 }
            guard Set(threads.map(\.id)).count == threads.count else { return nil }
            func signature(_ values: Comments) -> String {
                let last = values.nodes.compactMap { $0 }.last
                return "\(values.totalCount):\(last?.id ?? ""):\(last?.publishedAt ?? "")"
            }
            guard threads.allSatisfy({ $0.comments.totalCount >= 0 && $0.comments.totalCount <= connectionLimit }) else { return nil }
            return changeDigest(([updatedAt, signature(comments)] + threads.sorted { $0.id < $1.id }.map {
                "\($0.id):\(signature($0.comments))"
            }).joined(separator: "|"))
        }

        func observation(target: GitHubConversationPlan.Target, fingerprint: String, at: Date,
                         comments: [GitHubConversationComment]?) throws -> GitHubConversationObservation {
            guard number > 0, !repository.id.isEmpty,
                  GitHubNotificationURL.validate(repository.url.absoluteString + "/pull/\(number)") != nil else {
                throw GitHubAPIError.unexpectedResponse
            }
            return .init(id: id, repository: repository, number: number, fingerprint: fingerprint,
                         verifiedAt: at, comments: comments, lastRequestedAt: target.lastRequestedAt)
        }

        func normalizedComments(viewer: Actor, authored: Bool) throws -> [GitHubConversationComment]? {
            guard comments.complete, reviewThreads.complete,
                  reviewThreads.nodes.compactMap({ $0 }).allSatisfy({ $0.comments.complete }) else { return nil }
            var values: [GitHubConversationComment] = []
            func append(_ connection: Comments, thread: String?) throws {
                let nodes = connection.nodes.compactMap { $0 }
                for comment in nodes {
                    guard !comment.id.isEmpty else { throw GitHubAPIError.unexpectedResponse }
                    if thread != nil && comment.state != "SUBMITTED" { continue }
                    guard let published = comment.publishedAt, let url = comment.url,
                          let body = comment.body, let created = comment.createdAt else { throw GitHubAPIError.missingData }
                    let time = try date(published)
                    _ = try date(created)
                    guard let valid = GitHubNotificationURL.validate(url.absoluteString),
                          valid.path == "/\(repository.nameWithOwner)/pull/\(number)"
                            || valid.path == "/\(repository.nameWithOwner)/pull/\(number)/files",
                          valid.fragment?.hasPrefix(thread == nil ? "issuecomment-" : "discussion_r") == true else {
                        throw GitHubAPIError.unexpectedResponse
                    }
                    guard let actor = comment.author, !actor.login.isEmpty, !actor.isViewer(viewer) else { continue }
                    // Participation is established by authoritative thread membership before this comment.
                    let participated = try nodes.contains { prior in
                        guard prior.author?.isViewer(viewer) == true, let published = prior.publishedAt else { return false }
                        return try date(published) <= time
                    }
                    var reviewID: String?
                    if let review = comment.pullRequestReview, let submitted = review.submittedAt,
                       ["APPROVED", "CHANGES_REQUESTED"].contains(review.state),
                       abs(try date(submitted).timeIntervalSince(time)) <= 5 { reviewID = review.id }
                    values.append(.init(id: comment.id,
                        kind: thread == nil ? .newPRComment : comment.replyTo == nil ? .newInlineReviewComment : .newReviewThreadReply,
                        publishedAt: time, url: url, actorLogin: actor.login, isBot: actor.__typename == "Bot",
                        relevant: authored || participated || mentions(body, login: viewer.login), reviewID: reviewID, threadID: thread))
                }
            }
            try append(comments, thread: nil)
            for thread in reviewThreads.nodes.compactMap({ $0 }) { try append(thread.comments, thread: thread.id) }
            guard Set(values.map(\.id)).count == values.count else { throw GitHubAPIError.unexpectedResponse }
            return values
        }
    }

    private static func date(_ string: String) throws -> Date {
        if let value = try? Date.ISO8601FormatStyle().parse(string) { return value }
        if let value = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return value }
        throw GitHubAPIError.unexpectedResponse
    }

    // Explicit mention fallback only; quoted/code mentions do not establish relevance.
    static func mentions(_ body: String, login: String) -> Bool {
        var fenced = false
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle(); return false }
            return !fenced && !trimmed.hasPrefix(">") && !trimmed.contains("`") && !trimmed.contains("<")
        }.joined(separator: "\n")
        let pattern = "(?i)(?<![A-Za-z0-9_@/.-])@" + NSRegularExpression.escapedPattern(for: login) + "(?![A-Za-z0-9_-])"
        return lines.range(of: pattern, options: .regularExpression) != nil
    }

    static let probeQuery = """
    query ConversationProbe($ids: [ID!]!) {
      viewer { id databaseId login }
      rateLimit { remaining resetAt }
      nodes(ids: $ids) { ... on PullRequest {
        id number state updatedAt repository { id nameWithOwner url }
        comments(last: 1) { totalCount nodes { id publishedAt } }
        reviewThreads(first: 50) { totalCount pageInfo { hasNextPage } nodes {
          id comments(last: 1) { totalCount nodes { id publishedAt } }
        } }
      } }
    }
    """
    static let detailQuery = """
    query ConversationDetails($ids: [ID!]!) {
      viewer { id databaseId login }
      rateLimit { remaining resetAt }
      nodes(ids: $ids) { ... on PullRequest {
        id number state updatedAt repository { id nameWithOwner url }
        comments(first: 50) { totalCount pageInfo { hasNextPage } nodes {
          id publishedAt createdAt url body author { __typename login ... on User { id } ... on Bot { id } }
        } }
        reviewThreads(first: 50) { totalCount pageInfo { hasNextPage } nodes {
          id comments(first: 50) { totalCount pageInfo { hasNextPage } nodes {
            id publishedAt createdAt url body state replyTo { id }
            pullRequestReview { id state submittedAt }
            author { __typename login ... on User { id } ... on Bot { id } }
          } }
        } }
      } }
    }
    """
}
