import Foundation
import Testing

@MainActor
struct PullRequestDashboardTests {
    private let account = GitHubAccount(login: "octocat", avatarURL: URL(string: "https://github.com/avatar")!)
    private let empty = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [.tokenVisibility])

    @Test func startsIdleAndLoadsBothEmptySections() async {
        let empty = empty
        let dashboard = PullRequestDashboard(credential: { "test-token" }, fetch: { _, _, _ in empty })
        #expect(dashboard.authored.phase == .idle)
        dashboard.setAccount(account)
        dashboard.loadIfNeeded()
        #expect(dashboard.isLoading)
        await finish(dashboard)
        #expect(dashboard.authored.phase == .loaded)
        #expect(dashboard.reviews.phase == .loaded)
        #expect(dashboard.authored.result?.pullRequests.isEmpty == true)
        #expect(dashboard.reviews.result == empty)
        #expect(dashboard.authored.updatedAt != nil)
    }

    @Test(arguments: [false, true])
    func oneSectionFailureDoesNotHideOtherResults(failingReview: Bool) async {
        let empty = empty
        let dashboard = PullRequestDashboard(credential: { "test-token" }, fetch: { _, _, review in
            if review == failingReview { throw GitHubAPIError.forbidden }
            return empty
        })
        dashboard.setAccount(account)
        dashboard.refresh()
        await finish(dashboard)
        let successful = failingReview ? dashboard.authored : dashboard.reviews
        let failed = failingReview ? dashboard.reviews : dashboard.authored
        #expect(successful.result == empty)
        #expect(successful.phase == .loaded)
        #expect(failed.phase == .failed)
        #expect(failed.errorMessage?.contains("permissions") == true)
    }

    @Test func missingCredentialFailsWithoutFetching() {
        let dashboard = PullRequestDashboard(credential: { nil }, fetch: { _, _, _ in
            Issue.record("Missing credentials must not reach discovery")
            throw GitHubAPIError.invalidToken
        })
        dashboard.setAccount(account)
        dashboard.refresh()
        #expect(!dashboard.isLoading)
        #expect(dashboard.authored.errorMessage?.contains("Settings") == true)
        #expect(dashboard.reviews.phase == .failed)
    }

    @Test func freshnessAndExplicitRefresh() async {
        let empty = empty
        var date = Date(timeIntervalSince1970: 1000)
        var reads = 0
        let dashboard = PullRequestDashboard(credential: { reads += 1; return "test-token" }, now: { date },
                                             fetch: { _, _, _ in empty })
        dashboard.setAccount(account)
        dashboard.loadIfNeeded()
        dashboard.refresh()
        #expect(reads == 1) // A simultaneous refresh is ignored.
        await finish(dashboard)
        date += 59
        dashboard.loadIfNeeded()
        #expect(reads == 1)
        dashboard.refresh()
        #expect(reads == 2) // Manual refresh bypasses freshness.
        #expect(dashboard.authored.result == empty)
        #expect(dashboard.reviews.result == empty)
        await finish(dashboard)
        date += 60
        dashboard.loadIfNeeded()
        #expect(reads == 3)
        await finish(dashboard)
    }

    @Test func successfulRefreshClearsTransientCoverageWarning() async {
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.setAccount(account)
        dashboard.refresh()
        await service.waitForCalls(2)
        await service.failAll(error: GitHubAPIError.rateLimited)
        await finish(dashboard)
        #expect(DiscoveryCoveragePresentation(sections: [dashboard.authored, dashboard.reviews], errors: []).isWarning)
        dashboard.refresh()
        await service.waitForCalls(4)
        await service.resolveAll(result: empty)
        await finish(dashboard)
        let display = DiscoveryCoveragePresentation(sections: [dashboard.authored, dashboard.reviews], errors: [])
        #expect(!display.isWarning)
        #expect(!display.details.contains("rate limit"))
    }

    @Test func failureDoesNotAutomaticallyRetryOnRapidOpening() async {
        var reads = 0
        let dashboard = PullRequestDashboard(credential: { reads += 1; return "test-token" },
                                             fetch: { _, _, _ in throw GitHubAPIError.rateLimited })
        dashboard.setAccount(account)
        dashboard.loadIfNeeded()
        await finish(dashboard)
        dashboard.loadIfNeeded()
        #expect(reads == 1)
        #expect(dashboard.reviews.errorMessage == GitHubAPIError.rateLimited.localizedDescription)
    }


    @Test func loadsSectionsIndependentlyAndPreservesMetadata() async {
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.setAccount(account)
        dashboard.refresh()
        await service.waitForCalls(2)
        let authored = result(title: "Authored", truncated: true)
        await service.resolve(login: account.login, review: false, result: authored)
        await waitUntil { dashboard.authored.phase == .loaded }
        #expect(dashboard.reviews.phase == .loading)
        #expect(dashboard.authored.result == authored)
        #expect(dashboard.authored.result?.pullRequests.first?.reviewStatus == .approved)
        #expect(dashboard.authored.coverageMessages.contains { $0.contains("incomplete") })
        #expect(dashboard.authored.coverageMessages.contains { $0.contains("token") })
        #expect(!dashboard.authored.coverageMessages.contains { $0.contains("Team") })
        let reviews = result(title: "Review", review: true)
        await service.resolve(login: account.login, review: true, result: reviews)
        await finish(dashboard)
        #expect(dashboard.reviews.result == reviews)
        #expect(dashboard.reviews.coverageMessages.contains { $0.contains("Team review requests aren’t included") })
        #expect(!dashboard.reviews.coverageMessages.contains { $0.contains("incomplete") })
    }

    @Test func refreshRetainsResultsAndTimestampEvenWhenNetworkFails() async {
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.setAccount(account)
        dashboard.refresh()
        await service.waitForCalls(2)
        let previous = result(title: "Cached")
        await service.resolveAll(result: previous)
        await finish(dashboard)
        let updatedAt = dashboard.authored.updatedAt
        dashboard.refresh()
        #expect(dashboard.isLoading)
        #expect(dashboard.authored.result == previous)
        #expect(dashboard.reviews.result == previous)
        #expect(dashboard.authored.updatedAt == updatedAt)
        await service.waitForCalls(4)
        await service.failAll(error: GitHubAPIError.networkUnavailable)
        await finish(dashboard)
        #expect(dashboard.authored.phase == .failed)
        #expect(dashboard.authored.result == previous)
        #expect(dashboard.authored.updatedAt == updatedAt)
        #expect(dashboard.authored.errorMessage == GitHubAPIError.networkUnavailable.localizedDescription)
        dashboard.refresh()
        #expect(dashboard.authored.errorMessage == nil)
        await service.waitForCalls(6)
        await service.resolveAll(result: empty)
        await finish(dashboard)
        #expect(dashboard.authored.result == empty)
    }

    @Test func disconnectCancelsAndRejectsLateResponses() async {
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.setAccount(account)
        dashboard.refresh()
        await service.waitForCalls(2)
        dashboard.setAccount(nil)
        #expect(!dashboard.isLoading)
        #expect(dashboard.authored.result == nil && dashboard.reviews.result == nil)
        #expect(dashboard.account == nil)
        dashboard.refresh()
        await service.resolveAll(result: result(title: "Late private data"))
        await service.waitForFinishes(2)
        await Task.yield()
        #expect(dashboard.authored.phase == .idle && dashboard.reviews.phase == .idle)
        #expect(dashboard.authored.result == nil && dashboard.reviews.result == nil)
        #expect(await service.cancelledCount == 2)
        #expect(await service.callCount == 2)
    }

    @Test(arguments: [false, true])
    func reconnectUsesFreshSessionAndCurrentCredential(sameAccount: Bool) async {
        let service = ControlledDiscovery()
        var token = "old-test-token"
        let dashboard = PullRequestDashboard(credential: { token }, fetch: { account, token, review in
            try await service.fetch(account: account, token: token, review: review)
        })
        dashboard.setAccount(account)
        dashboard.refresh()
        await service.waitForCalls(2)
        dashboard.setAccount(nil)
        token = "new-test-token"
        let newAccount = GitHubAccount(login: sameAccount ? account.login : "another-user", avatarURL: account.avatarURL)
        dashboard.setAccount(newAccount)
        dashboard.loadIfNeeded()
        await service.waitForCalls(4)
        await service.resolveAll(result: result(title: "Old session"), token: "old-test-token")
        await service.waitForFinishes(2)
        await Task.yield()
        #expect(dashboard.isLoading)
        #expect(dashboard.authored.result == nil && dashboard.reviews.result == nil)
        #expect(dashboard.account == newAccount)
        let latest = result(title: "Current session")
        await service.resolveAll(result: latest, token: "new-test-token")
        await finish(dashboard)
        #expect(dashboard.authored.result == latest && dashboard.reviews.result == latest)
        #expect(await service.logins(for: "new-test-token") == [newAccount.login, newAccount.login])
    }

    @Test(arguments: [GitHubAPIError.invalidToken, .forbidden, .rateLimited, .networkUnavailable, .partialData])
    func errorsAreActionableAndSanitized(error: GitHubAPIError) async {
        let dashboard = PullRequestDashboard(credential: { "test-token" }, fetch: { _, _, _ in throw error })
        dashboard.setAccount(account)
        dashboard.refresh()
        await finish(dashboard)
        #expect(dashboard.authored.errorMessage != nil)
        #expect(dashboard.reviews.errorMessage == dashboard.authored.errorMessage)
        #expect(dashboard.authored.result == nil)
        #expect(dashboard.authored.phase == .failed)
    }

    @Test func keychainAndUnknownFailuresNeverExposeUnderlyingError() {
        struct SecretError: Error, LocalizedError {
            var errorDescription: String? { "sensitive-server-response" }
        }
        for error: any Error in [SecretError(), KeychainCredentialStore.StorageError.signingRequired] {
            let dashboard = PullRequestDashboard(credential: { throw error }, fetch: { _, _, _ in
                Issue.record("Credential failures must not fetch")
                throw GitHubAPIError.invalidToken
            })
            dashboard.setAccount(account)
            dashboard.refresh()
            #expect(dashboard.authored.errorMessage?.contains("sensitive-server-response") == false)
            #expect(dashboard.authored.phase == .failed)
        }
    }

    @Test func invalidCursorWarningDiffersFromLimitWarning() {
        let value = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [.invalidCursor],
                                                     coverageLimitations: [.tokenVisibility])
        let state = PullRequestSectionState(phase: .loaded, result: value)
        #expect(state.coverageMessages.contains { $0.contains("cursor") })
        #expect(!state.coverageMessages.contains { $0.contains("limit was reached") })
        #expect(state.coverageMessages.contains { $0.contains("inaccessible") })
    }

    @Test func connectionOwnsDashboardSessionWithoutFetchingUntilOpened() async throws {
        let http = MockHTTP { request in
            let body: String
            if request.url?.path == "/user" {
                body = MockHTTP.accountJSON
            } else {
                #expect(request.url?.path == "/graphql")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                body = #"{"data":{"viewer":{"login":"octocat"},"search":{"issueCount":0,"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}"#
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let keychain = MockKeychain()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        await connection.connect(token: "test-token")
        #expect(connection.dashboard.account == connection.account)
        #expect(connection.dashboard.authored.phase == .idle)
        #expect(keychain.reads == 2)
        connection.dashboard.loadIfNeeded()
        await finish(connection.dashboard)
        #expect(keychain.reads == 3)
        #expect(connection.dashboard.authored.result?.pullRequests.isEmpty == true)
        #expect(connection.dashboard.reviews.phase == .loaded)
        connection.disconnect()
        #expect(connection.account == nil && connection.dashboard.account == nil)
        #expect(connection.dashboard.authored.result == nil && connection.dashboard.reviews.result == nil)
        await connection.connect(token: "test-token")
        #expect(connection.dashboard.authored.phase == .idle)
        #expect(connection.dashboard.authored.result == nil)
    }

    @Test func failedDisconnectPreservesConnectedDashboard() async {
        let http = MockHTTP()
        let keychain = MockKeychain()
        let connection = GitHubConnection(client: http.client, credentials: keychain.store)
        await connection.connect(token: "test-token")
        keychain.deleteStatus = -25308 // errSecInteractionNotAllowed
        connection.disconnect()
        #expect(connection.account != nil)
        #expect(connection.dashboard.account == connection.account)
        #expect(connection.errorMessage != nil)
    }

    private func makeDashboard(_ service: ControlledDiscovery) -> PullRequestDashboard {
        PullRequestDashboard(credential: { "test-token" }, fetch: { account, token, review in
            try await service.fetch(account: account, token: token, review: review)
        })
    }

    private func result(title: String, truncated: Bool = false, review: Bool = false) -> GitHubPullRequestDiscoveryResult {
        let pr = GitHubPullRequest(id: title, number: 1, title: title, url: URL(string: "https://github.com/a/b/pull/1")!,
                                  repository: GitHubRepository(id: "repo", nameWithOwner: "a/b", url: URL(string: "https://github.com/a/b")!),
                                  authorLogin: review ? "review-author" : account.login, isDraft: false,
                                  createdAt: .distantPast, updatedAt: .distantPast, reviewStatus: .approved,
                                  latestReviews: nil, checks: nil, reviewRequests: nil)
        return GitHubPullRequestDiscoveryResult(pullRequests: [pr], truncationReasons: truncated ? [.resultLimit] : [],
                                                coverageLimitations: review ? [.tokenVisibility, .directReviewRequestsOnly] : [.tokenVisibility])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }

    private func finish(_ dashboard: PullRequestDashboard) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while dashboard.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!dashboard.isLoading)
    }
}


// Intentionally completes even after cancellation to exercise stale-session protection.
private actor ControlledDiscovery {
    struct Request {
        let login: String
        let token: String
        let review: Bool
        let continuation: CheckedContinuation<GitHubPullRequestDiscoveryResult, any Error>
    }
    private var pending: [Request] = []
    private var calls: [(login: String, token: String)] = []
    private var finishedCount = 0
    private(set) var cancelledCount = 0
    var callCount: Int { calls.count }

    func fetch(account: GitHubAccount, token: String, review: Bool) async throws -> GitHubPullRequestDiscoveryResult {
        let result: GitHubPullRequestDiscoveryResult = try await withCheckedThrowingContinuation { continuation in
            calls.append((account.login, token))
            pending.append(Request(login: account.login, token: token, review: review, continuation: continuation))
        }
        finishedCount += 1
        if Task.isCancelled { cancelledCount += 1 }
        return result
    }

    func logins(for token: String) -> [String] { calls.filter { $0.token == token }.map(\.login) }

    func waitForCalls(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while calls.count < count, ContinuousClock.now < deadline { await Task.yield() }
        #expect(calls.count >= count)
    }

    func waitForFinishes(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while finishedCount < count, ContinuousClock.now < deadline { await Task.yield() }
        #expect(finishedCount >= count)
    }

    func resolve(login: String, review: Bool, result: GitHubPullRequestDiscoveryResult) {
        guard let index = pending.firstIndex(where: { $0.login == login && $0.review == review }) else {
            Issue.record("No pending request to resolve")
            return
        }
        pending.remove(at: index).continuation.resume(returning: result)
    }

    func resolveAll(result: GitHubPullRequestDiscoveryResult, token: String? = nil) {
        let matches = pending.filter { token == nil || $0.token == token }
        pending.removeAll { token == nil || $0.token == token }
        for request in matches { request.continuation.resume(returning: result) }
    }

    func failAll(error: any Error) {
        let matches = pending
        pending.removeAll()
        for request in matches { request.continuation.resume(throwing: error) }
    }
}

@MainActor
struct MultiTokenDashboardTests {
    private let account = GitHubAccount(id: 1, login: "octocat", avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1")!)
    private let empty = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [.tokenVisibility])

    @Test func successfulScopesDeduplicateWithinEachSectionAndKeepCoverage() async {
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        let rows = scopes()
        dashboard.setConnections(rows, refresh: false)
        dashboard.loadIfNeeded()
        dashboard.refresh()
        await service.waitForCalls(4)
        let first = result([pr("shared"), pr("personal")], reasons: [.resultLimit])
        let second = result([pr("shared"), pr("organization")], reasons: [.invalidCursor])
        await service.resolveAll(result: first, token: rows[0].storageAccount)
        await service.resolveAll(result: second, token: rows[1].storageAccount)
        await finish(dashboard)
        #expect(dashboard.authored.result?.pullRequests.map(\.id) == ["organization", "personal", "shared"])
        #expect(dashboard.reviews.result?.pullRequests.count == 3)
        #expect(dashboard.sources[rows[0].id]?.authored.result == first)
        #expect(dashboard.sources[rows[1].id]?.authored.result == second)
        #expect(dashboard.authored.result?.truncationReasons == [.resultLimit, .invalidCursor])
        #expect(await service.callCount == 4)
    }

    @Test(arguments: [0, 1]) func partialFailureAndRateLimitStayPerToken(failedIndex: Int) async {
        let rows = scopes()
        let failedToken = rows[failedIndex].storageAccount
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, fetch: { _, token, _ in
            if token == failedToken { throw GitHubAPIError.rateLimited }
            return GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [.pageLimit], coverageLimitations: [.tokenVisibility])
        })
        dashboard.setConnections(rows, refresh: true)
        await finish(dashboard)
        let successful = rows[1 - failedIndex]
        #expect(dashboard.sources[rows[failedIndex].id]?.authored.phase == .failed)
        #expect(dashboard.sources[successful.id]?.authored.phase == .loaded)
        #expect(dashboard.authored.result?.truncationReasons == [.pageLimit])
        #expect(dashboard.authored.phase == .failed)
        #expect(dashboard.authored.errorMessage?.contains(rows[failedIndex].resourceOwner) == true)
        #expect(dashboard.authored.errorMessage?.contains("rate limit") == true)
        #expect(dashboard.authored.result != nil)
    }

    @Test func mergeConflictsRemainUnknownAcrossThreeTokensAndOrderingIsStable() {
        let approved = result([pr("shared", decision: .approved), pr("other")])
        let changes = result([pr("shared", decision: .changesRequested)])
        let merged = GitHubPullRequestDiscoveryResult.merged([approved, changes, approved])
        #expect(merged.pullRequests.first { $0.id == "shared" }?.reviewStatus == .unknown)
        #expect(merged.coverageLimitations.contains(.conflictingMetadata))
        #expect(merged.pullRequests.map(\.id) == ["other", "shared"])
        #expect(GitHubPullRequestDiscoveryResult.merged([changes, approved]).pullRequests.map(\.id) == ["other", "shared"])
        let state = PullRequestSectionState(phase: .loaded, result: merged)
        #expect(state.coverageMessages.contains { $0.contains("disagree") })
    }

    @Test func mergeUsesNodeIDAndPreservesSafelyAvailableMetadata() {
        let unknown = pr("same", decision: .unknown)
        let complete = pr("same", decision: .approved, author: "octocat")
        let otherNode = pr("different", decision: .approved)
        // Same title, repository, number and URL are deliberately not deduplication keys.
        let merged = GitHubPullRequestDiscoveryResult.merged([result([unknown]), result([complete, otherNode])])
        #expect(merged.pullRequests.count == 2)
        #expect(merged.pullRequests.first { $0.id == "same" }?.authorLogin == "octocat")
        #expect(merged.pullRequests.first { $0.id == "same" }?.reviewStatus == .approved)
        #expect(!merged.coverageLimitations.contains(.conflictingMetadata))
    }

    @Test func newerUnknownDecisionDoesNotInheritOlderApproval() {
        let older = pr("same", decision: .approved)
        let newer = pr("same", decision: .unknown, updated: Date(timeIntervalSince1970: 10))
        let merged = GitHubPullRequestDiscoveryResult.merged([result([older]), result([newer])])
        #expect(merged.pullRequests.first?.reviewStatus == .unknown)
    }

    @Test func refreshAfterAddingTokenBypassesFreshnessAndPreservesLoadedRows() async {
        let rows = scopes()
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.setConnections([rows[0]], refresh: true)
        await service.waitForCalls(2)
        let existing = result([pr("personal")])
        await service.resolveAll(result: existing)
        await finish(dashboard)
        dashboard.setConnections(rows, refresh: true)
        #expect(dashboard.authored.result == existing)
        await service.waitForCalls(6)
        await service.resolveAll(result: existing, token: rows[0].storageAccount)
        await service.resolveAll(result: result([pr("organization")]), token: rows[1].storageAccount)
        await finish(dashboard)
        #expect(dashboard.authored.result?.pullRequests.count == 2)
    }

    @Test func removalRetainsSharedAndRemainingPRsAndRejectsActiveResponses() async {
        let rows = scopes()
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.setConnections(rows, refresh: true)
        await service.waitForCalls(4)
        let personal = result([pr("personal"), pr("shared")])
        await service.resolveAll(result: personal, token: rows[0].storageAccount)
        await service.resolveAll(result: result([pr("organization"), pr("shared")]), token: rows[1].storageAccount)
        await finish(dashboard)
        dashboard.refresh()
        await service.waitForCalls(8)
        dashboard.setConnections([rows[0]], refresh: true)
        #expect(dashboard.authored.result == personal)
        await service.waitForCalls(10)
        await service.resolveAll(result: result([pr("removed-private")]), token: rows[1].storageAccount)
        await service.resolveAll(result: personal, token: rows[0].storageAccount)
        await finish(dashboard)
        #expect(dashboard.authored.result == personal)
        #expect(dashboard.sources[rows[1].id] == nil)
        #expect(await service.cancelledCount >= 2)
    }

    @Test func replacementInvalidatesOnlyItsCacheAndRejectsOldResponses() async {
        var rows = scopes()
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.setConnections(rows, refresh: true)
        await service.waitForCalls(4)
        await service.resolveAll(result: result([pr("old-private")]), token: rows[0].storageAccount)
        let organization = result([pr("organization")])
        await service.resolveAll(result: organization, token: rows[1].storageAccount)
        await finish(dashboard)
        dashboard.refresh()
        await service.waitForCalls(8)
        let oldReference = rows[0].storageAccount
        rows[0].credentialID = UUID()
        dashboard.setConnections(rows, refresh: true)
        #expect(dashboard.authored.result == organization)
        await service.waitForCalls(12)
        await service.resolveAll(result: result([pr("stale-secret")]), token: oldReference)
        await service.resolveAll(result: result([pr("new-private")]), token: rows[0].storageAccount)
        await service.resolveAll(result: organization, token: rows[1].storageAccount)
        await finish(dashboard)
        #expect(dashboard.authored.result?.pullRequests.map(\.id) == ["new-private", "organization"])
        dashboard.setConnections([], refresh: true)
        #expect(dashboard.account == nil && dashboard.sources.isEmpty)
        #expect(dashboard.authored.result == nil && dashboard.reviews.result == nil)
    }

    @Test func thirdTokenWaitsForBoundedWorkerSlot() async {
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        let rows = scopes() + [GitHubTokenConnection(id: UUID(), account: account, resourceOwner: "third")]
        dashboard.setConnections(rows, refresh: true)
        await service.waitForCalls(4)
        #expect(await service.callCount == 4)
        await service.resolveAll(result: empty, token: rows[0].storageAccount)
        await service.waitForCalls(6)
        await service.resolveAll(result: empty)
        await finish(dashboard)
        #expect(await service.callCount == 6)
        #expect(dashboard.authored.phase == .loaded)
    }

    @Test func missingCredentialFailsOnlyThatScopeAndRetainsItsPreviousResults() async {
        let rows = scopes()
        var missing = false
        let service = ControlledDiscovery()
        let dashboard = PullRequestDashboard(scopedCredential: { reference in
            missing && reference == rows[0].storageAccount ? nil : reference
        }, fetch: { account, token, review in
            try await service.fetch(account: account, token: token, review: review)
        })
        dashboard.setConnections(rows, refresh: true)
        await service.waitForCalls(4)
        let previous = result([pr("previous")])
        await service.resolveAll(result: previous)
        await finish(dashboard)
        let timestamp = dashboard.sources[rows[0].id]?.authored.updatedAt
        missing = true
        dashboard.refresh()
        #expect(dashboard.sources[rows[0].id]?.authored.phase == .failed)
        #expect(dashboard.sources[rows[0].id]?.authored.result == previous)
        #expect(dashboard.sources[rows[0].id]?.authored.updatedAt == timestamp)
        await service.waitForCalls(6)
        await service.resolveAll(result: empty)
        await finish(dashboard)
        #expect(dashboard.sources[rows[1].id]?.authored.phase == .loaded)
        #expect(dashboard.authored.result?.pullRequests.count == 1)
    }

    private func scopes() -> [GitHubTokenConnection] {
        [GitHubTokenConnection(id: UUID(), account: account, resourceOwner: "personal"),
         GitHubTokenConnection(id: UUID(), account: account, resourceOwner: "apify")]
    }

    private func makeDashboard(_ service: ControlledDiscovery) -> PullRequestDashboard {
        PullRequestDashboard(scopedCredential: { $0 }, fetch: { account, token, review in
            try await service.fetch(account: account, token: token, review: review)
        })
    }

    private func pr(_ id: String, decision: GitHubReviewStatus = .approved, author: String? = nil,
                    updated: Date = Date(timeIntervalSince1970: 0)) -> GitHubPullRequest {
        GitHubPullRequest(id: id, number: 1, title: "Same title", url: URL(string: "https://github.com/a/b/pull/1")!,
                          repository: GitHubRepository(id: "repo", nameWithOwner: "a/b", url: URL(string: "https://github.com/a/b")!),
                          authorLogin: author, isDraft: false, createdAt: .distantPast, updatedAt: updated,
                          reviewStatus: decision, latestReviews: nil, checks: nil, reviewRequests: nil)
    }

    private func result(_ prs: [GitHubPullRequest], reasons: Set<GitHubPullRequestDiscoveryResult.TruncationReason> = []) -> GitHubPullRequestDiscoveryResult {
        GitHubPullRequestDiscoveryResult(pullRequests: prs, truncationReasons: reasons, coverageLimitations: [.tokenVisibility])
    }

    private func finish(_ dashboard: PullRequestDashboard) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while dashboard.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!dashboard.isLoading)
    }
}

extension MultiTokenDashboardTests {
    @Test func openingBeforeRestoreFinishesStillLoadsTheRestoredScopes() async {
        let service = ControlledDiscovery()
        let dashboard = makeDashboard(service)
        dashboard.loadIfNeeded()
        dashboard.setConnections(scopes(), refresh: false)
        await service.waitForCalls(4)
        await service.resolveAll(result: empty)
        await finish(dashboard)
        #expect(dashboard.authored.phase == .loaded)
    }
}

extension MultiTokenDashboardTests {
    @Test func compatibleBoundedReviewsSurviveTokenOrderAndKeepLimitations() throws {
        let base = pr("same")
        func observation(_ reviews: [GitHubPullRequestReview], _ limitations: Set<GitHubLatestReviews.Limitation>) -> GitHubPullRequest {
            GitHubPullRequest(id: base.id, number: base.number, title: base.title, url: base.url,
                repository: base.repository, authorLogin: base.authorLogin, isDraft: base.isDraft,
                createdAt: base.createdAt, updatedAt: base.updatedAt, reviewStatus: .unknown,
                latestReviews: .init(reviews: reviews, limitations: limitations), checks: nil, reviewRequests: nil)
        }
        let approval = GitHubPullRequestReview(id: "a", authorLogin: "bot[bot]", state: .approved)
        let comment = GitHubPullRequestReview(id: "b", authorLogin: "bob", state: .commented)
        let a = result([observation([approval], [.reviewerLimit])])
        let b = result([observation([comment], [.missingReview])])
        for inputs in [[a, b], [b, a], [a, b, a]] {
            let merged = GitHubPullRequestDiscoveryResult.merged(inputs)
            let pr = try #require(merged.pullRequests.first)
            #expect(pr.latestReviews?.reviews == [approval, comment])
            #expect(pr.latestReviews?.limitations == [.reviewerLimit, .missingReview])
            #expect(pr.reviewStatus == .unknown)
            #expect(pr.reviewPresentation.label == "At least 1 approval")
            #expect(!merged.coverageLimitations.contains(.conflictingMetadata))
        }
        let replacement = GitHubPullRequestReview(id: "new", authorLogin: "bot[bot]", state: .dismissed)
        let conflict = GitHubPullRequestDiscoveryResult.merged([a, result([observation([replacement], [.reviewerLimit])]), a])
        #expect(conflict.pullRequests.first?.latestReviews == nil)
        #expect(conflict.coverageLimitations.contains(.conflictingMetadata))
        let complete = result([observation([approval, comment], [])])
        for inputs in [[a, complete], [complete, a]] {
            #expect(GitHubPullRequestDiscoveryResult.merged(inputs).pullRequests.first?.latestReviews?.limitations == [])
        }
    }

    @Test func completeReviewerDetailsReplaceUnavailableDetailsWithoutInventingConflict() throws {
        let base = pr("same")
        func withDetails(_ details: GitHubLatestReviews) -> GitHubPullRequest {
            GitHubPullRequest(id: base.id, number: base.number, title: base.title, url: base.url,
                              repository: base.repository, authorLogin: base.authorLogin, isDraft: base.isDraft,
                              createdAt: base.createdAt, updatedAt: base.updatedAt, reviewStatus: base.reviewStatus,
                              latestReviews: details, checks: nil, reviewRequests: nil)
        }
        let complete = GitHubLatestReviews(reviews: [GitHubPullRequestReview(id: "r", authorLogin: "reviewer", state: .approved)], limitations: [])
        let unavailable = GitHubLatestReviews(reviews: [], limitations: [.unavailable])
        let merged = GitHubPullRequestDiscoveryResult.merged([result([withDetails(unavailable)]), result([withDetails(complete)])])
        #expect(merged.pullRequests.first?.latestReviews == complete)
        #expect(!merged.coverageLimitations.contains(.conflictingMetadata))
        let contradictory = GitHubLatestReviews(reviews: [GitHubPullRequestReview(id: "r", authorLogin: "reviewer", state: .changesRequested)], limitations: [])
        let conflicted = GitHubPullRequestDiscoveryResult.merged([result([withDetails(complete)]), result([withDetails(contradictory)]), result([withDetails(complete)])])
        #expect(conflicted.pullRequests.first?.latestReviews == nil)
        #expect(conflicted.coverageLimitations.contains(.conflictingMetadata))
    }
}

struct PullRequestInboxTests {
    @Test func authoredAndDraftCountsAreMutuallyExclusiveAndKeepReviewMembership() {
        func pr(_ id: String, draft: Bool) -> GitHubPullRequest {
            GitHubPullRequest(id: id, number: 1, title: "Title", url: URL(string: "https://github.com/a/b/pull/1")!,
                              repository: GitHubRepository(id: "r", nameWithOwner: "a/b", url: URL(string: "https://github.com/a/b")!),
                              authorLogin: "a", isDraft: draft, createdAt: .distantPast, updatedAt: .distantPast,
                              reviewStatus: nil, latestReviews: nil, checks: nil, reviewRequests: nil)
        }
        let state = PullRequestSectionState(phase: .failed,
            result: GitHubPullRequestDiscoveryResult(pullRequests: [pr("open", draft: false), pr("draft", draft: true)],
                truncationReasons: [], coverageLimitations: [.tokenVisibility]), errorMessage: "Offline")
        #expect(PullRequestInbox.authored.pullRequests(in: state).map(\.id) == ["open"])
        #expect(PullRequestInbox.drafts.pullRequests(in: state).map(\.id) == ["draft"])
        #expect(PullRequestInbox.review.pullRequests(in: state).count == 2)
        #expect(PullRequestInbox.authored.label(in: state) == "My PRs 1")
        #expect(PullRequestInbox.drafts.label(in: state) == "Drafts 1")
        #expect(PullRequestInbox.review.label(in: .init()) == "Review —")
        #expect(PullRequestInbox.drafts.label(in: PullRequestSectionState(phase: .loaded,
            result: GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: []))) == "Drafts 0")
    }
}

struct DiscoveryCoveragePresentationTests {
    @Test func structuralLimitationsAreInformational() {
        let state = PullRequestSectionState(phase: .loaded, result: .init(pullRequests: [],
            truncationReasons: [], coverageLimitations: [.tokenVisibility, .directReviewRequestsOnly]))
        let display = DiscoveryCoveragePresentation(sections: [state], errors: [])
        #expect(!display.isWarning)
        #expect(display.label == "Discovery info")
        #expect(display.details.contains("Team review requests"))
        #expect(display.details.contains("visible to your tokens"))
    }

    @Test(arguments: [GitHubPullRequestDiscoveryResult.TruncationReason.resultLimit,
                      .pageLimit, .searchLimit, .invalidCursor, .reviewRequestLimit])
    func truncationIsVisible(reason: GitHubPullRequestDiscoveryResult.TruncationReason) {
        let state = PullRequestSectionState(phase: .loaded, result: .init(pullRequests: [],
            truncationReasons: [reason], coverageLimitations: [.tokenVisibility]))
        let display = DiscoveryCoveragePresentation(sections: [state], errors: [])
        #expect(display.isWarning)
        #expect(display.accessibilityLabel.contains("Partial results"))
        #expect(display.accessibilityLabel.contains("incomplete"))
        #expect(display.systemImage == "exclamationmark.triangle.fill")
    }

    @Test func failuresAndConflictsAreVisibleEvenWithoutResults() {
        let failure = PullRequestSectionState(phase: .failed, errorMessage: "Acme: Rate limited")
        let success = PullRequestSectionState(phase: .loaded, result: .init(pullRequests: [],
            truncationReasons: [], coverageLimitations: [.tokenVisibility]))
        for sections in [[failure], [success, failure]] {
            let display = DiscoveryCoveragePresentation(sections: sections, errors: [])
            #expect(display.isWarning)
            #expect(display.accessibilityLabel.contains("Acme: Rate limited"))
            #expect(display.label == "GitHub needs attention")
        }
        #expect(DiscoveryCoveragePresentation(sections: [success], errors: ["Connection failed"]).isWarning)
        let conflict = PullRequestSectionState(result: .init(pullRequests: [], truncationReasons: [],
            coverageLimitations: [.conflictingMetadata]))
        #expect(DiscoveryCoveragePresentation(sections: [conflict], errors: []).isWarning)
        #expect(!DiscoveryCoveragePresentation(sections: [success], errors: []).isWarning)
    }
}
