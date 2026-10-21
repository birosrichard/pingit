import Foundation
import Testing

@MainActor
private final class VirtualSyncClock {
    var time: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, any Error>)] = [:]
    var clock: SyncClock {
        SyncClock(now: { self.time }, sleep: { deadline in
            try Task.checkCancellation()
            guard deadline > self.time else { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.sleepers[id] = (deadline, continuation)
                }
            } onCancel: {
                Task { @MainActor in self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
            }
            try Task.checkCancellation()
        })
    }
    func advance(_ seconds: TimeInterval) {
        time += seconds
        let due = sleepers.filter { $0.value.0 <= time }
        for (id, value) in due {
            sleepers.removeValue(forKey: id)
            value.1.resume()
        }
    }
}

@MainActor
private final class SyncFixture {
    let clock = VirtualSyncClock()
    let preferences = BackgroundSyncPreferences()
    let account = GitHubAccount(login: "octocat", avatarURL: URL(string: "https://github.com/avatar")!)
    let empty = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [])
    var calls: [String] = []
    var errors: [String: GitHubAPIError] = [:]
    var hold = false
    var pending: [CheckedContinuation<GitHubPullRequestDiscoveryResult, any Error>] = []
    lazy var dashboard = PullRequestDashboard(scopedCredential: { $0 },
        now: { Date(timeIntervalSince1970: 1000 + self.clock.time) }, clock: clock.clock, jitter: { 0 },
        preferences: preferences, fetch: { [weak self] _, token, _ in
            guard let self else { throw CancellationError() }
            return try await self.fetch(token)
        })

    func rows(_ count: Int = 1) -> [GitHubTokenConnection] {
        (0..<count).map { GitHubTokenConnection(id: UUID(), account: account, resourceOwner: "owner-\($0)") }
    }
    func fetch(_ token: String) async throws -> GitHubPullRequestDiscoveryResult {
        calls.append(token)
        if hold {
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        if let error = errors[token] { throw error }
        return empty
    }
    func release() {
        let values = pending
        pending = []
        for value in values { value.resume(returning: empty) }
    }
    func start(_ rows: [GitHubTokenConnection]? = nil) {
        dashboard.startBackgroundSync()
        dashboard.setConnections(rows ?? self.rows(), refresh: false)
    }
    func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }
    func finished(at deadline: TimeInterval?) async {
        await wait { !self.dashboard.isRefreshing && self.dashboard.nextAutomaticRefresh == deadline }
    }
}

@MainActor
struct BackgroundSyncTests {
    @Test func defaultStartsWithoutPopoverAndStopsAtShutdown() async {
        let f = SyncFixture()
        #expect(f.preferences.enabled && f.preferences.interval == 300)
        f.start()
        defer { f.dashboard.shutdown() }
        await f.finished(at: 300)
        #expect(f.calls.count == 2)
        #expect(f.dashboard.authored.result == f.empty)
        f.clock.advance(299)
        await Task.yield()
        #expect(f.calls.count == 2)
        f.clock.advance(1)
        await f.finished(at: 600)
        #expect(f.calls.count == 4)
        f.dashboard.shutdown()
        f.clock.advance(3600)
        await Task.yield()
        #expect(f.dashboard.nextAutomaticRefresh == nil && f.calls.count == 4)
    }

    @Test func noConnectionsAndUnvalidatedConnectionsStayInactive() async {
        let f = SyncFixture()
        f.dashboard.startBackgroundSync()
        defer { f.dashboard.shutdown() }
        #expect(f.dashboard.nextAutomaticRefresh == nil)
        f.dashboard.setConnections([.init(id: UUID(), account: nil, resourceOwner: "invalid")], refresh: false)
        #expect(f.dashboard.nextAutomaticRefresh == nil)
        f.dashboard.setConnections(f.rows(), refresh: false)
        await f.finished(at: 300)
        #expect(f.calls.count == 2)
        f.dashboard.setConnections([], refresh: true)
        #expect(f.dashboard.nextAutomaticRefresh == nil)
        #expect(f.dashboard.authored.result == nil)
    }

    @Test func disableManualRefreshAndReenable() async {
        let f = SyncFixture()
        f.preferences.enabled = false
        f.start()
        defer { f.dashboard.shutdown() }
        #expect(f.calls.isEmpty && f.dashboard.nextAutomaticRefresh == nil)
        f.dashboard.refresh()
        await f.wait { f.calls.count == 2 && !f.dashboard.isRefreshing }
        f.clock.advance(100)
        f.preferences.enabled = true
        #expect(f.dashboard.nextAutomaticRefresh == 300)
        f.preferences.enabled = false
        #expect(f.dashboard.nextAutomaticRefresh == nil)
        f.clock.advance(1000)
        f.preferences.enabled = true
        await f.finished(at: 1400)
        #expect(f.calls.count == 4)
    }

    @Test func intervalChangesRearmOneSchedulerWithoutDuplicateRequests() async {
        let f = SyncFixture()
        f.start()
        defer { f.dashboard.shutdown() }
        await f.finished(at: 300)
        f.clock.advance(100)
        for minutes in [10, 15, 30, 2] { f.preferences.intervalMinutes = minutes }
        f.dashboard.startBackgroundSync()
        #expect(f.dashboard.nextAutomaticRefresh == 120)
        f.clock.advance(20)
        await f.finished(at: 240)
        #expect(f.calls.count == 4)
        f.preferences.intervalMinutes = 10
        #expect(f.dashboard.nextAutomaticRefresh == 720)
    }

    @Test func manualAndPopoverRefreshResetDeadlinesAndKeepImmediateData() async {
        let f = SyncFixture()
        f.start()
        defer { f.dashboard.shutdown() }
        await f.finished(at: 300)
        f.clock.advance(30)
        f.dashboard.loadIfNeeded()
        #expect(f.calls.count == 2 && f.dashboard.authored.result == f.empty)
        f.dashboard.refresh()
        await f.finished(at: 330)
        f.clock.advance(60)
        f.dashboard.loadIfNeeded()
        #expect(f.dashboard.authored.result == f.empty)
        await f.finished(at: 390)
        #expect(f.calls.count == 6)
    }

    @Test func activeManualBackgroundPopoverAndConnectionEventsCoalesce() async {
        let f = SyncFixture()
        let rows = f.rows()
        f.hold = true
        f.start(rows)
        defer { f.dashboard.shutdown() }
        await f.wait { f.calls.count == 2 }
        f.dashboard.refresh()
        f.dashboard.loadIfNeeded()
        f.dashboard.setConnections(rows, refresh: true)
        f.dashboard.systemDidWake()
        f.preferences.intervalMinutes = 10
        #expect(f.calls.count == 2 && f.dashboard.nextAutomaticRefresh == nil)
        f.hold = false
        f.release()
        await f.finished(at: 600)
        #expect(f.calls.count == 2)
    }

    @Test func sleepWakeSkipsMissedIntervalsAndKeepsFreshSchedule() async {
        let f = SyncFixture()
        f.start()
        defer { f.dashboard.shutdown() }
        await f.finished(at: 300)
        f.dashboard.systemWillSleep()
        f.clock.advance(100)
        f.dashboard.refresh()
        #expect(f.dashboard.nextAutomaticRefresh == nil && f.calls.count == 2)
        f.dashboard.systemDidWake()
        #expect(f.dashboard.nextAutomaticRefresh == 300)
        f.dashboard.systemWillSleep()
        f.clock.advance(10000)
        f.dashboard.systemDidWake()
        f.dashboard.systemDidWake()
        await f.finished(at: 10400)
        #expect(f.calls.count == 4)
    }

    @Test func connectionChangesDrainCancelledWorkAndRejectStaleData() async {
        let f = SyncFixture()
        var rows = f.rows(2)
        f.hold = true
        f.start(rows)
        defer { f.dashboard.shutdown() }
        await f.wait { f.calls.count == 4 }
        let oldReference = rows[0].storageAccount
        rows[0].credentialID = UUID()
        f.dashboard.setConnections([rows[0]], refresh: true)
        f.dashboard.setConnections([rows[0]], refresh: true)
        #expect(f.calls.count == 4 && f.dashboard.authored.result == nil)
        f.hold = false
        f.release()
        await f.finished(at: 300)
        #expect(f.calls.count == 6 && f.calls.suffix(2).allSatisfy { $0 == rows[0].storageAccount })
        #expect(f.calls.suffix(2).allSatisfy { $0 != oldReference })
        #expect(f.dashboard.sources.count == 1)
        f.dashboard.setConnections(rows, refresh: true)
        await f.finished(at: 300)
        #expect(f.calls.count == 10 && f.dashboard.sources.count == 2)
        f.dashboard.setConnections([], refresh: true)
        #expect(f.dashboard.authored.result == nil && f.dashboard.lastSuccessfulRefreshAt == nil)
    }

    @Test func sleepDuringFlightRejectsLateResultsAndRetriesOnceOnWake() async {
        let f = SyncFixture()
        f.hold = true
        f.start()
        defer { f.dashboard.shutdown() }
        await f.wait { f.calls.count == 2 }
        f.dashboard.systemWillSleep()
        f.clock.advance(1000)
        f.release()
        await f.wait { !f.dashboard.isRefreshing }
        #expect(f.dashboard.authored.result == nil)
        f.hold = false
        f.dashboard.systemDidWake()
        await f.finished(at: 1300)
        #expect(f.calls.count == 4)
    }

    @Test func networkBackoffIsBoundedAndRecoveryResetsIt() async {
        let f = SyncFixture()
        let rows = f.rows()
        f.errors[rows[0].storageAccount] = .networkUnavailable
        f.start(rows)
        defer { f.dashboard.shutdown() }
        await f.finished(at: 60)
        #expect(f.dashboard.lastSuccessfulRefreshAt == nil)
        #expect(f.dashboard.lastAttemptAt == Date(timeIntervalSince1970: 1000))
        f.clock.advance(60)
        await f.finished(at: 180)
        f.clock.advance(120)
        await f.finished(at: 420)
        f.errors = [:]
        f.clock.advance(240)
        await f.finished(at: 720)
        #expect(f.dashboard.lastSuccessfulRefreshAt == Date(timeIntervalSince1970: 1420))
        var state = ConnectionSyncState()
        for _ in 0..<30 { state.failed(GitHubAPIError.networkUnavailable, time: 0, date: .now, jitter: 1) }
        #expect(state.retryAt == 1800)
        var jittered = ConnectionSyncState()
        jittered.failed(GitHubAPIError.networkUnavailable, time: 0, date: .now, jitter: 1)
        #expect(jittered.retryAt == 72)
    }

    @Test func primaryAndSecondaryLimitsRespectDeadlineAcrossWakeAndManualRefresh() async {
        let f = SyncFixture()
        let rows = f.rows()
        f.errors[rows[0].storageAccount] = .rateLimitedUntil(Date(timeIntervalSince1970: 1900))
        f.start(rows)
        defer { f.dashboard.shutdown() }
        await f.finished(at: 900)
        f.dashboard.refresh()
        f.dashboard.loadIfNeeded()
        #expect(f.calls.count == 2)
        f.dashboard.systemWillSleep()
        f.clock.advance(500)
        f.dashboard.systemDidWake()
        #expect(f.dashboard.nextAutomaticRefresh == 900)
        f.errors[rows[0].storageAccount] = .rateLimited
        f.clock.advance(400)
        await f.finished(at: 1020)
        f.errors = [:]
        f.clock.advance(120)
        await f.finished(at: 1320)
        #expect(f.calls.count == 6)
    }

    @Test func partialFailureKeepsStaleTimestampsAndHealthyTokensIndependent() async {
        let f = SyncFixture()
        let rows = f.rows(2)
        f.start(rows)
        defer { f.dashboard.shutdown() }
        await f.finished(at: 300)
        let previous = f.dashboard.sources[rows[1].id]?.authored.updatedAt
        f.errors[rows[1].storageAccount] = .rateLimitedUntil(Date(timeIntervalSince1970: 3000))
        f.clock.advance(300)
        await f.finished(at: 600)
        #expect(f.dashboard.sources[rows[1].id]?.authored.updatedAt == previous)
        #expect(f.dashboard.sources[rows[1].id]?.authored.result == f.empty)
        #expect(f.dashboard.sources[rows[1].id]?.authored.phase == .failed)
        #expect(f.dashboard.authored.errorMessage?.contains("owner-1") == true)
        #expect(f.dashboard.authored.updatedAt == previous)
        f.clock.advance(300)
        await f.finished(at: 900)
        #expect(f.calls.count == 10)
        #expect(f.calls.suffix(2).allSatisfy { $0 == rows[0].storageAccount })
        #expect(f.dashboard.sources[rows[1].id]?.authored.updatedAt == previous)
    }

    @Test func revokedTokenPausesUntilExplicitRetryOrReplacement() async {
        let f = SyncFixture()
        var rows = f.rows()
        f.errors[rows[0].storageAccount] = .invalidToken
        f.start(rows)
        defer { f.dashboard.shutdown() }
        await f.wait { f.calls.count == 2 && !f.dashboard.isRefreshing }
        #expect(f.dashboard.nextAutomaticRefresh == nil)
        f.clock.advance(10000)
        f.dashboard.systemDidWake()
        #expect(f.calls.count == 2 && f.dashboard.nextAutomaticRefresh == nil)
        f.errors = [:]
        f.dashboard.refresh()
        await f.finished(at: 10300)
        rows[0].credentialID = UUID()
        f.dashboard.setConnections(rows, refresh: true)
        await f.finished(at: 10300)
        #expect(f.calls.count == 6)
    }

    @Test func watchdogCancelsBoundedFlightAndRejectsLateSuccess() async {
        let f = SyncFixture()
        f.hold = true
        f.start()
        defer { f.dashboard.shutdown() }
        await f.wait { f.calls.count == 2 }
        f.dashboard.refresh()
        f.clock.advance(120)
        await f.wait { f.dashboard.authored.errorMessage?.contains("timed out") == true }
        #expect(f.calls.count == 2)
        f.release()
        await f.finished(at: 180)
        #expect(f.dashboard.lastSuccessfulRefreshAt == nil && f.dashboard.authored.result == nil)
        f.hold = false
        f.clock.advance(60)
        await f.finished(at: 480)
        #expect(f.calls.count == 4)
    }

    @Test func preferencesPersistOnlyValidatedUserChoices() throws {
        let name = "pingit.sync-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = BackgroundSyncPreferences(defaults: defaults)
        #expect(preferences.enabled && preferences.intervalMinutes == 5)
        preferences.enabled = false
        preferences.intervalMinutes = 15
        preferences.intervalMinutes = 3
        let restored = BackgroundSyncPreferences(defaults: defaults)
        #expect(!restored.enabled && restored.intervalMinutes == 15)
        #expect(Set(defaults.persistentDomain(forName: name)?.keys.map { $0 } ?? []) == ["sync.enabled", "sync.intervalMinutes"])
    }
}

extension BackgroundSyncTests {
    @Test func failedAttemptNeverMovesSuccessfulTimestamp() async {
        let f = SyncFixture()
        let rows = f.rows()
        f.start(rows)
        defer { f.dashboard.shutdown() }
        await f.finished(at: 300)
        let success = f.dashboard.lastSuccessfulRefreshAt
        f.errors[rows[0].storageAccount] = .networkUnavailable
        f.clock.advance(300)
        await f.finished(at: 360)
        #expect(f.dashboard.lastSuccessfulRefreshAt == success)
        #expect(f.dashboard.authored.updatedAt == success)
        #expect(f.dashboard.lastAttemptAt == Date(timeIntervalSince1970: 1300))
    }

    @Test func mixedSectionErrorsKeepSecondaryLimitAndAllowHealthySectionData() async {
        let clock = VirtualSyncClock()
        let account = GitHubAccount(login: "octocat", avatarURL: URL(string: "https://github.com/avatar")!)
        let empty = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [])
        let dashboard = PullRequestDashboard(credential: { "fixture" }, clock: clock.clock, jitter: { 0 }, fetch: { _, _, review in
            if review { throw GitHubAPIError.rateLimited }
            return empty
        })
        dashboard.startBackgroundSync()
        defer { dashboard.shutdown() }
        dashboard.setAccount(account)
        let deadline = ContinuousClock.now + .seconds(5)
        while dashboard.nextAutomaticRefresh != 60, ContinuousClock.now < deadline { await Task.yield() }
        #expect(dashboard.nextAutomaticRefresh == 60)
        #expect(dashboard.authored.result == empty && dashboard.reviews.phase == .failed)
        let attempt = dashboard.lastAttemptAt
        dashboard.refresh()
        #expect(dashboard.lastAttemptAt == attempt && !dashboard.isRefreshing)
    }
}
