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
    }

    enum CoverageLimitation: Sendable {
        // Search cannot report repositories hidden by a token's permissions or approval state.
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
        for account: GitHubAccount, token: String, maximumResults: Int = 50
    ) async throws -> GitHubPullRequestDiscoveryResult {
        try await fetch(for: account, token: token, maximumResults: maximumResults, reviewRequests: false)
    }

    func reviewRequestedPullRequests(
        for account: GitHubAccount, token: String, maximumResults: Int = 50
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
        let variables = Variables(query: "is:pr is:open \(filter) sort:updated-desc",
                                  first: min(50, maximumResults), after: nil, includeReviewRequests: reviewRequests)
        let response: GitHubPullRequestSearchResponse = try await client.graphQL(
            query: GitHubPullRequestSearchResponse.query, variables: variables, token: token)
        guard response.viewer.login.caseInsensitiveCompare(login) == .orderedSame else {
            throw GitHubDiscoveryError.accountMismatch
        }
        var values: [GitHubPullRequest] = []
        var seen: Set<String> = []
        var reasons: Set<GitHubPullRequestDiscoveryResult.TruncationReason> = []
        for node in response.search.nodes {
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
        if response.search.pageInfo.hasNextPage { reasons.insert(.resultLimit) }
        if response.search.issueCount > 1000 { reasons.insert(.searchLimit) }
        var coverage: Set<GitHubPullRequestDiscoveryResult.CoverageLimitation> = [.tokenVisibility]
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
