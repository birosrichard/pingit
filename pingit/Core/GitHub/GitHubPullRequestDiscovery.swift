import Foundation

struct GitHubPullRequestDiscoveryResult: Equatable, Sendable {
    let pullRequests: [GitHubPullRequest]
    let truncationReasons: Set<TruncationReason>
    let coverageLimitations: Set<CoverageLimitation>

    var isTruncated: Bool { !truncationReasons.isEmpty }

    enum TruncationReason: Sendable {
        case resultLimit
        case searchLimit
    }

    enum CoverageLimitation: Sendable {
        // Search cannot report repositories hidden by a token's permissions or approval state.
        case tokenVisibility
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
        try Task.checkCancellation()
        let login = try validatedLogin(account.login)
        guard (1...1000).contains(maximumResults) else { throw GitHubDiscoveryError.invalidLimit }
        let variables = Variables(query: "is:pr is:open author:\(login) sort:updated-desc",
                                  first: min(50, maximumResults), after: nil, includeReviewRequests: false)
        let response: GitHubPullRequestSearchResponse = try await client.graphQL(
            query: GitHubPullRequestSearchResponse.query, variables: variables, token: token)
        guard response.viewer.login.caseInsensitiveCompare(login) == .orderedSame else {
            throw GitHubDiscoveryError.accountMismatch
        }
        var values: [GitHubPullRequest] = []
        var seen: Set<String> = []
        for node in response.search.nodes {
            try Task.checkCancellation()
            guard let node else { throw GitHubAPIError.missingData }
            let pr = try node.domain()
            guard node.state == .open, pr.authorLogin?.caseInsensitiveCompare(login) == .orderedSame else { continue }
            if seen.insert(pr.id).inserted { values.append(pr) }
        }
        var reasons: Set<GitHubPullRequestDiscoveryResult.TruncationReason> = []
        if response.search.pageInfo.hasNextPage { reasons.insert(.resultLimit) }
        if response.search.issueCount > 1000 { reasons.insert(.searchLimit) }
        return GitHubPullRequestDiscoveryResult(pullRequests: values, truncationReasons: reasons,
                                                coverageLimitations: [.tokenVisibility])
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
