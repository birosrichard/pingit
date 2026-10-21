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
        #expect(keychain.reads == 0)
        connection.dashboard.loadIfNeeded()
        await finish(connection.dashboard)
        #expect(keychain.reads == 1)
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
                                  latestReviews: nil, checkStatus: nil, reviewRequests: nil)
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
