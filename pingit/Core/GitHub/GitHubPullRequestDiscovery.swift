import Foundation

struct GitHubPullRequestDiscoveryResult: Equatable, Sendable {
    let pullRequests: [GitHubPullRequest]
    let truncationReasons: Set<TruncationReason>
    let coverageLimitations: Set<CoverageLimitation>

    var isTruncated: Bool { !truncationReasons.isEmpty }

    enum TruncationReason: Sendable {
        case resultLimit
        case searchLimit
        case reviewRequestLimit
        case pageLimit
        case invalidCursor
    }

    enum CoverageLimitation: Sendable {
        // Search cannot report repositories hidden by a token's permissions or approval state.
        case checkDataUnavailable
        case conflictingMetadata
        case tokenVisibility
        case directReviewRequestsOnly
    }
}

enum GitHubDiscoveryError: Error, LocalizedError, Equatable {
    case invalidLimit
    case invalidAccount
    case accountMismatch

    var errorDescription: String? {
        switch self {
        case .invalidLimit: "Choose a pull request limit between 1 and 1,000."
        case .invalidAccount: "The GitHub account login is invalid. Reconnect and try again."
        case .accountMismatch: "The saved credential belongs to a different GitHub account. Reconnect and try again."
        }
    }
}

struct GitHubPullRequestDiscovery: Sendable {
    private let client: GitHubClient

    init(client: GitHubClient = GitHubClient()) {
        self.client = client
    }

    // Supply the account validated by GitHubConnection and its existing Keychain token.
    func authoredPullRequests(
        for account: GitHubAccount, token: String, maximumResults: Int = 200
    ) async throws -> GitHubPullRequestDiscoveryResult {
        try await fetch(for: account, token: token, maximumResults: maximumResults, reviewRequests: false)
    }

    func reviewRequestedPullRequests(
        for account: GitHubAccount, token: String, maximumResults: Int = 200
    ) async throws -> GitHubPullRequestDiscoveryResult {
        try await fetch(for: account, token: token, maximumResults: maximumResults, reviewRequests: true)
    }

    private func fetch(
        for account: GitHubAccount, token: String, maximumResults: Int, reviewRequests: Bool
    ) async throws -> GitHubPullRequestDiscoveryResult {
        try Task.checkCancellation()
        let login = try validatedLogin(account.login)
        guard (1...1000).contains(maximumResults) else { throw GitHubDiscoveryError.invalidLimit }
        let filter = reviewRequests
            ? "user-review-requested:@me -author:\(login) draft:false"
            : "author:\(login)"
        let query = "is:pr is:open \(filter) sort:updated-desc"
        var values: [GitHubPullRequest] = []
        var seen: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        var scanned = 0
        var reasons: Set<GitHubPullRequestDiscoveryResult.TruncationReason> = []

        // Bound requests independently of unique results: duplicates/stale search hits
        // must not turn a small result limit into unlimited network activity.
        for page in 1...20 {
            try Task.checkCancellation()
            let first = min(50, maximumResults - values.count, 1000 - scanned)
            let variables = Variables(query: query, first: first, after: cursor, includeReviewRequests: reviewRequests)
            let response: GitHubPullRequestSearchResponse = try await client.graphQL(
                query: GitHubPullRequestSearchResponse.query, variables: variables, token: token,
                recoverPartialData: GitHubPullRequestSearchResponse.recoverUnavailableChecks)
            guard response.viewer.login.caseInsensitiveCompare(login) == .orderedSame else {
                throw GitHubDiscoveryError.accountMismatch
            }
            let search = response.search
            guard search.issueCount >= 0, search.nodes.count <= first else { throw GitHubAPIError.unexpectedResponse }
            scanned += search.nodes.count
            if search.issueCount > 1000 { reasons.insert(.searchLimit) }
            for node in search.nodes {
                try Task.checkCancellation()
                guard let node else { throw GitHubAPIError.missingData }
                let pr = try node.domain()
                guard node.state == .open else { continue }
                if reviewRequests {
                    guard !pr.isDraft, pr.authorLogin?.caseInsensitiveCompare(login) != .orderedSame else { continue }
                    guard let requests = node.reviewRequests else { throw GitHubAPIError.partialData }
                    if requests.pageInfo.hasNextPage { reasons.insert(.reviewRequestLimit) }
                    // Search can lag behind a submitted/removed review request.
                    guard requests.contains(login: login) else { continue }
                } else {
                    guard pr.authorLogin?.caseInsensitiveCompare(login) == .orderedSame else { continue }
                }
                if seen.insert(pr.id).inserted { values.append(pr) }
            }
            guard search.pageInfo.hasNextPage else { break }
            if values.count >= maximumResults { reasons.insert(.resultLimit); break }
            if scanned >= 1000 { reasons.insert(.searchLimit); break }
            if page == 20 { reasons.insert(.pageLimit); break }
            guard let next = search.pageInfo.endCursor, !next.isEmpty, cursors.insert(next).inserted else {
                reasons.insert(.invalidCursor)
                break
            }
            cursor = next
        }
        try Task.checkCancellation()
        // Preserve encounter order for ties, including when search changes between pages.
        values = values.enumerated().sorted {
            if $0.element.updatedAt == $1.element.updatedAt { return $0.offset < $1.offset }
            return $0.element.updatedAt > $1.element.updatedAt
        }.map(\.element)
        var coverage: Set<GitHubPullRequestDiscoveryResult.CoverageLimitation> = [.tokenVisibility]
        if values.contains(where: { $0.checks?.limitation != nil }) { coverage.insert(.checkDataUnavailable) }
        if reviewRequests { coverage.insert(.directReviewRequestsOnly) }
        return GitHubPullRequestDiscoveryResult(pullRequests: values, truncationReasons: reasons,
                                                coverageLimitations: coverage)
    }

    private func validatedLogin(_ login: String) throws -> String {
        guard (1...39).contains(login.utf8.count), login.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        }) else { throw GitHubDiscoveryError.invalidAccount }
        return login
    }

    private struct Variables: Encodable, Sendable {
        let query: String
        let first: Int
        let after: String?
        let includeReviewRequests: Bool
    }
}


extension GitHubPullRequestDiscoveryResult {
    static func merged(_ results: [Self]) -> Self {
        var byID: [String: GitHubPullRequest] = [:]
        var conflictingDecisions: Set<String> = []
        var conflictingReviews: Set<String> = []
        var conflictingRequests: Set<String> = []
        var coverage = results.reduce(into: Set<CoverageLimitation>()) { $0.formUnion($1.coverageLimitations) }
        for result in results {
            for pr in result.pullRequests {
                guard let old = byID[pr.id] else { byID[pr.id] = pr; continue }
                let newest = pr.updatedAt > old.updatedAt ? pr : old
                let other = pr.updatedAt > old.updatedAt ? old : pr
                let sameSnapshot = newest.updatedAt == other.updatedAt
                let decisions = [old.reviewStatus, pr.reviewStatus].compactMap { $0 }.filter { $0 != .unknown }
                let conflict = Set(decisions.map(\.rawValue)).count > 1
                if conflict { conflictingDecisions.insert(pr.id); coverage.insert(.conflictingMetadata) }
                let status: GitHubReviewStatus? = conflictingDecisions.contains(pr.id) ? .unknown : sameSnapshot
                    ? decisions.first ?? newest.reviewStatus : newest.reviewStatus
                var details = newest.latestReviews ?? (sameSnapshot ? other.latestReviews : nil)
                if sameSnapshot, let left = newest.latestReviews, let right = other.latestReviews, left != right {
                    if left.limitations.contains(.unavailable) {
                        details = right
                    } else if right.limitations.contains(.unavailable) {
                        details = left
                    } else if left.limitations.isEmpty && right.reviews.allSatisfy(left.reviews.contains) {
                        details = left
                    } else if right.limitations.isEmpty && left.reviews.allSatisfy(right.reviews.contains) {
                        details = right
                    } else if !left.limitations.isEmpty && !right.limitations.isEmpty,
                              !left.reviews.contains(where: { a in right.reviews.contains { b in
                                  (a.id == b.id || (a.authorLogin != nil &&
                                      a.authorLogin?.lowercased() == b.authorLogin?.lowercased())) && a != b
                              } }) {
                        // Compatible bounded observations can add evidence, never prove completeness.
                        let combined = Array(Set(left.reviews.map(\.id) + right.reviews.map(\.id))).sorted()
                        details = GitHubLatestReviews(reviews: combined.compactMap { id in
                            left.reviews.first { $0.id == id } ?? right.reviews.first { $0.id == id }
                        }, limitations: left.limitations.union(right.limitations))
                    } else {
                        conflictingReviews.insert(pr.id)
                        coverage.insert(.conflictingMetadata)
                    }
                }
                let requestsDisagree = sameSnapshot && old.reviewRequests != nil && pr.reviewRequests != nil
                    && old.reviewRequests != pr.reviewRequests
                if requestsDisagree { conflictingRequests.insert(pr.id) }
                if requestsDisagree || (sameSnapshot && old.isDraft != pr.isDraft) { coverage.insert(.conflictingMetadata) }
                byID[pr.id] = GitHubPullRequest(
                    id: newest.id, number: newest.number, title: newest.title, url: newest.url,
                    repository: newest.repository, authorLogin: newest.authorLogin ?? (sameSnapshot ? other.authorLogin : nil),
                    isDraft: sameSnapshot ? old.isDraft || pr.isDraft : newest.isDraft, createdAt: newest.createdAt, updatedAt: newest.updatedAt,
                    reviewStatus: status,
                    latestReviews: conflictingReviews.contains(pr.id) ? nil : details,
                    checks: newest.checks,
                    reviewRequests: conflictingRequests.contains(pr.id) ? nil : newest.reviewRequests ?? (sameSnapshot ? other.reviewRequests : nil))
            }
        }
        let observations = Dictionary(grouping: results.flatMap(\.pullRequests), by: \.id)
        let enriched = byID.values.map { value in
            var value = value
            let current = observations[value.id, default: []].filter { $0.updatedAt == value.updatedAt }
            let heads = Set(current.compactMap(\.headRefOid))
            let stats = current.compactMap(\.diffStatistics)
            if heads.count > 1 {
                value.headRefOid = nil
                value.diffStatistics = nil
                value.checks = .unavailable(headOid: nil, reason: .conflicting)
                coverage.insert(.conflictingMetadata)
            } else {
                value.headRefOid = heads.first
                let diffConflict = stats.contains(where: { $0 != stats.first })
                value.diffStatistics = diffConflict ? nil : stats.first
                let checks = GitHubCheckSnapshot.merged(current.compactMap(\.currentChecks), headOid: value.headRefOid)
                value.checks = current.contains { $0.checks != nil } ? checks.snapshot : nil
                if diffConflict || checks.conflicted { coverage.insert(.conflictingMetadata) }
            }
            return value
        }
        return Self(pullRequests: enriched.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }, truncationReasons: results.reduce(into: []) { $0.formUnion($1.truncationReasons) },
                    coverageLimitations: coverage)
    }
}
