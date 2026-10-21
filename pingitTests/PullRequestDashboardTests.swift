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

    @Test func oneSectionFailureDoesNotHideOtherResults() async {
        let empty = empty
        let dashboard = PullRequestDashboard(credential: { "test-token" }, fetch: { _, _, review in
            if review { throw GitHubAPIError.forbidden }
            return empty
        })
        dashboard.setAccount(account)
        dashboard.refresh()
        await finish(dashboard)
        #expect(dashboard.authored.result == empty)
        #expect(dashboard.authored.phase == .loaded)
        #expect(dashboard.reviews.phase == .failed)
        #expect(dashboard.reviews.errorMessage?.contains("permissions") == true)
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

    private func finish(_ dashboard: PullRequestDashboard) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while dashboard.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!dashboard.isLoading)
    }
}
