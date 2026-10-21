import Foundation
import Testing

@MainActor
private final class MockNotificationService: NotificationService {
    enum Failure: Error { case synthetic }
    var status: NotificationPermission = .authorized
    var requestedStatus: NotificationPermission = .authorized
    var requestFails = false
    var deliveryFails = false
    var holdStatus = false
    var holdDelivery = false
    var statusCalls = 0
    var requestCalls = 0
    var attempts: [NotificationMessage] = []
    var delivered: [NotificationMessage] = []
    var statuses: [CheckedContinuation<NotificationPermission, Never>] = []
    var deliveries: [CheckedContinuation<Void, Never>] = []

    func authorizationStatus() async -> NotificationPermission {
        statusCalls += 1
        if holdStatus { return await withCheckedContinuation { statuses.append($0) } }
        return status
    }
    func requestAuthorization() async throws {
        requestCalls += 1
        if requestFails { throw Failure.synthetic }
        status = requestedStatus
    }
    func deliver(_ message: NotificationMessage) async throws {
        attempts.append(message)
        if holdDelivery { await withCheckedContinuation { deliveries.append($0) } }
        if deliveryFails { throw Failure.synthetic }
        delivered.append(message)
    }
    func releaseStatus(_ status: NotificationPermission) {
        let values = statuses
        statuses = []
        holdStatus = false
        for value in values { value.resume(returning: status) }
    }
    func releaseDelivery() {
        let values = deliveries
        deliveries = []
        holdDelivery = false
        for value in values { value.resume() }
    }
}

@MainActor
private final class NotificationFixture {
    let service = MockNotificationService()
    let preferences = NotificationPreferences()
    lazy var coordinator = NotificationCoordinator(service: service, preferences: preferences)
    func event(_ kind: PullRequestChangeEvent.Kind = .reviewRequested, id: String = "event-1",
               prID: String = "PR_1", title: String? = "Improve tests", actor: String? = nil,
               url: String = "https://github.com/owner/repository/pull/1",
               repository: String = "owner/repository", number: Int = 1) throws -> PullRequestChangeEvent {
        let link = try #require(URL(string: url))
        let repositoryURL = try #require(URL(string: "https://github.com/owner/repository"))
        return .init(id: id, kind: kind, pullRequestID: prID,
            repository: .init(id: "R_1", nameWithOwner: repository, url: repositoryURL), number: number,
            title: title, url: link, observedAt: .init(timeIntervalSince1970: 1000), actorLogin: actor,
            signal: .membership, previousState: "old", currentState: "new", sourceIDs: ["synthetic-scope"])
    }
    func wait(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
    }
    func finish() async { await wait { !self.coordinator.isDelivering } }
    func enableAll() {
        preferences.enabled = true
        preferences.reviewRequestRemoved = true
        preferences.readyForReview = true
    }
}

@MainActor
struct NotificationPreferenceTests {
    @Test func defaultsAreOptInAndConservative() {
        let p = NotificationPreferences()
        #expect(!p.enabled && !p.sound)
        #expect(p.reviewRequested && p.approved && p.changesRequested)
        #expect(!p.reviewRequestRemoved && !p.readyForReview)
        #expect(!p.allows(.reviewRequested))
        p.enabled = true
        #expect(p.allows(.reviewRequested) && p.allows(.approved) && p.allows(.changesRequested))
        #expect(!p.allows(.reviewRequestRemoved) && !p.allows(.readyForReview))
    }

    @Test func persistsOnlyBooleanPreferences() throws {
        let name = "pingit.notifications.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let p = NotificationPreferences(defaults: defaults)
        p.enabled = true
        p.reviewRequested = false
        p.reviewRequestRemoved = true
        p.approved = false
        p.changesRequested = false
        p.readyForReview = true
        p.sound = true
        let restored = NotificationPreferences(defaults: defaults)
        #expect(restored.enabled && restored.sound)
        #expect(!restored.reviewRequested && restored.reviewRequestRemoved)
        #expect(!restored.approved && !restored.changesRequested && restored.readyForReview)
        let stored = try #require(defaults.persistentDomain(forName: name))
        #expect(stored.count == 7)
        #expect(stored.keys.allSatisfy { $0.hasPrefix("notifications.") })
        #expect(stored.values.allSatisfy { $0 is Bool })
    }
}

@MainActor
struct NotificationPermissionTests {
    @Test(arguments: [NotificationPermission.notDetermined, .denied, .authorized, .provisional, .unavailable])
    func statusIsReadWithoutPrompting(status: NotificationPermission) async {
        let f = NotificationFixture()
        f.service.status = status
        #expect(f.coordinator.permission == .unknown)
        await f.coordinator.refreshAuthorization()
        #expect(f.coordinator.permission == status)
        #expect(f.service.requestCalls == 0)
    }

    @Test(arguments: [NotificationPermission.authorized, .denied])
    func explicitRequestUsesActualSystemState(status: NotificationPermission) async {
        let f = NotificationFixture()
        f.service.status = .notDetermined
        f.service.requestedStatus = status
        await f.coordinator.requestPermission()
        #expect(f.coordinator.permission == status)
        #expect(f.service.requestCalls == 1)
        #expect(!f.coordinator.isRequestingPermission && f.coordinator.errorMessage == nil)
        await f.coordinator.requestPermission()
        #expect(f.service.requestCalls == 1)
    }

    @Test func requestFailureIsSanitizedAndDoesNotGrantPermission() async {
        let f = NotificationFixture()
        f.service.status = .notDetermined
        f.service.requestFails = true
        await f.coordinator.requestPermission()
        #expect(f.coordinator.permission == .notDetermined)
        #expect(f.coordinator.errorMessage == "Couldn’t request notification permission. Try again in Settings.")
        #expect(!f.coordinator.isRequestingPermission)
    }

    @Test func overlappingPermissionRequestsPromptOnce() async {
        let f = NotificationFixture()
        f.service.holdStatus = true
        let first = Task { await f.coordinator.requestPermission() }
        await f.wait { f.service.statusCalls == 1 }
        await f.coordinator.requestPermission()
        f.service.releaseStatus(.notDetermined)
        await first.value
        #expect(f.service.requestCalls == 1)
    }

    @Test func obsoleteStatusCannotReplaceNewerStatus() async {
        let f = NotificationFixture()
        f.service.holdStatus = true
        let first = Task { await f.coordinator.refreshAuthorization() }
        await f.wait { f.service.statusCalls == 1 }
        f.service.holdStatus = false
        f.service.status = .denied
        await f.coordinator.refreshAuthorization()
        f.service.releaseStatus(.authorized)
        await first.value
        #expect(f.coordinator.permission == .denied)
    }
}

@MainActor
struct NotificationDeliveryTests {
    @Test func disabledMasterDoesNotQueryOrDeliver() async throws {
        let f = NotificationFixture()
        f.coordinator.consume([try f.event()])
        await f.finish()
        #expect(f.service.statusCalls == 0 && f.service.attempts.isEmpty)
    }

    @Test(arguments: [PullRequestChangeEvent.Kind.reviewRequested, .reviewRequestRemoved, .approved, .changesRequested, .readyForReview])
    func eachEventToggleFiltersIndependently(kind: PullRequestChangeEvent.Kind) async throws {
        let f = NotificationFixture()
        f.enableAll()
        switch kind {
        case .reviewRequested: f.preferences.reviewRequested = false
        case .reviewRequestRemoved: f.preferences.reviewRequestRemoved = false
        case .approved: f.preferences.approved = false
        case .changesRequested: f.preferences.changesRequested = false
        case .readyForReview: f.preferences.readyForReview = false
        }
        f.coordinator.consume([try f.event(kind)])
        await f.finish()
        #expect(f.service.attempts.isEmpty)
        #expect(f.service.statusCalls == 0)
    }

    @Test(arguments: [NotificationPermission.unknown, .notDetermined, .denied, .authorized, .provisional, .unavailable])
    func permissionGatesDeliveryWithoutRequesting(status: NotificationPermission) async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.service.status = status
        f.coordinator.consume([try f.event()])
        await f.finish()
        #expect(f.service.delivered.count == (status.allowsDelivery ? 1 : 0))
        #expect(f.service.requestCalls == 0)
        // Denied/undetermined events are discarded, never replayed on a later grant.
        f.service.status = .authorized
        f.coordinator.consume([try f.event()])
        await f.finish()
        #expect(f.service.delivered.count == (status.allowsDelivery ? 1 : 0))
    }

    @Test func duplicateIDsAcrossBatchesAreSuppressedButNewTransitionsDeliver() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        let event = try f.event()
        f.coordinator.consume([event, event])
        f.coordinator.consume([event])
        await f.finish()
        f.coordinator.consume([event, try f.event(id: "event-2")])
        await f.finish()
        #expect(f.service.delivered.count == 2)
        #expect(Set(f.service.delivered.map(\.identifier)).count == 2)
        #expect(Set(f.service.delivered.map(\.threadIdentifier)).count == 1)
    }

    @Test func differentPullRequestsHaveDifferentNotificationGroups() throws {
        let f = NotificationFixture()
        let first = try #require(NotificationMessage(event: try f.event(), sound: false))
        let second = try #require(NotificationMessage(event: try f.event(id: "event-2", prID: "PR_2",
            url: "https://github.com/owner/repository/pull/2", number: 2), sound: false))
        #expect(first.threadIdentifier != second.threadIdentifier)
    }

    @Test func missingTitleAndActorUseUsefulFallbacks() throws {
        let f = NotificationFixture()
        let message = try #require(NotificationMessage(event: try f.event(title: nil), sound: false))
        #expect(message.body == "Pull request #1")
        #expect(message.subtitle == "owner/repository #1")
        #expect(!message.sound)
    }

    @Test(arguments: [PullRequestChangeEvent.Kind.reviewRequested, .reviewRequestRemoved, .approved, .changesRequested, .readyForReview])
    func contentHasEventRepositoryTitleAndSafeURL(kind: PullRequestChangeEvent.Kind) throws {
        let f = NotificationFixture()
        let message = try #require(NotificationMessage(event: try f.event(kind, actor: "reviewer"), sound: true))
        let expected: String
        switch kind {
        case .reviewRequested: expected = "Review requested"
        case .reviewRequestRemoved: expected = "Review request removed"
        case .approved: expected = "Pull request approved"
        case .changesRequested: expected = "Changes requested"
        case .readyForReview: expected = "Ready for review"
        }
        #expect(message.title == expected)
        #expect(message.subtitle == "owner/repository #1")
        #expect(message.body == "Improve tests — @reviewer")
        #expect(message.pullRequestURL == "https://github.com/owner/repository/pull/1")
        #expect(message.sound)
        #expect(!message.identifier.contains("event-1"))
        #expect(!message.threadIdentifier.contains("PR_1"))
    }

    @Test func textIsBoundedAndControlsAreRemoved() throws {
        let f = NotificationFixture()
        let message = try #require(NotificationMessage(event: try f.event(title: "\n" + String(repeating: "a", count: 200), actor: "\nreviewer\u{202E}"), sound: false))
        #expect(message.body == String(repeating: "a", count: 180) + "… — @reviewer")
    }

    @Test func invalidOrMismatchedMetadataIsDiscarded() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.coordinator.consume([
            try f.event(id: "bad-url", url: "https://evil.example/owner/repository/pull/1"),
            try f.event(id: "bad-repo", repository: "different/repository"),
            try f.event(id: "bad-number", number: 2),
            try f.event(id: "missing-pr", prID: ""), try f.event(id: "")
        ])
        await f.finish()
        #expect(f.service.attempts.isEmpty && f.service.statusCalls == 0)
    }

    @Test func failuresDoNotRetryOrPreventOtherEvents() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.service.deliveryFails = true
        let event = try f.event()
        f.coordinator.consume([event])
        await f.finish()
        #expect(f.coordinator.errorMessage == "Couldn’t deliver a notification. Check macOS notification settings.")
        f.service.deliveryFails = false
        f.coordinator.consume([event, try f.event(id: "event-2")])
        await f.finish()
        #expect(f.service.attempts.count == 2 && f.service.delivered.count == 1)
        #expect(f.coordinator.errorMessage == nil)
    }

    @Test func preferencesCancelWaitingDelivery() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.service.holdStatus = true
        f.coordinator.consume([try f.event()])
        await f.wait { f.service.statusCalls == 1 }
        f.preferences.enabled = false
        f.service.releaseStatus(.authorized)
        await f.finish()
        #expect(f.service.attempts.isEmpty)
        f.coordinator.stop()
    }

    @Test func assigningAnUnchangedPreferenceKeepsPendingDelivery() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.service.holdStatus = true
        f.coordinator.consume([try f.event()])
        await f.wait { f.service.statusCalls == 1 }
        f.preferences.enabled = true
        #expect(f.coordinator.isDelivering)
        f.service.releaseStatus(.authorized)
        await f.finish()
        #expect(f.service.delivered.count == 1)
    }

    @Test func permissionIsRecheckedBetweenSubmissions() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.service.holdDelivery = true
        f.coordinator.consume([try f.event(), try f.event(id: "event-2")])
        await f.wait { f.service.attempts.count == 1 }
        f.service.status = .denied
        f.service.releaseDelivery()
        await f.finish()
        #expect(f.service.attempts.count == 1 && f.coordinator.permission == .denied)
    }

    @Test func queueAndDeduplicationHaveExplicitBounds() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        let events = try (0..<600).map { try f.event(id: "event-\($0)") }
        f.coordinator.consume(events)
        await f.finish()
        #expect(f.service.attempts.count == NotificationCoordinator.pendingLimit)
        f.coordinator.consume([try f.event(id: "event-599")])
        await f.finish()
        #expect(f.service.attempts.count == NotificationCoordinator.pendingLimit)
        // Old identities may leave the bounded cache; Phase 5B prevents durable replay.
        f.coordinator.consume([try f.event(id: "event-0")])
        await f.finish()
        #expect(f.service.attempts.count == NotificationCoordinator.pendingLimit + 1)
    }
}

@MainActor
struct NotificationActivationTests {
    @Test func activationUsesInjectedOpenerAndPropagatesFailure() {
        var opened: [URL] = []
        let activation = NotificationActivation { opened.append($0); return false }
        #expect(!activation.activate("https://github.com/owner/repository/pull/1"))
        #expect(opened.map(\.absoluteString) == ["https://github.com/owner/repository/pull/1"])
    }

    @Test func validCanonicalPRURLCanOpen() {
        var count = 0
        let activation = NotificationActivation { _ in count += 1; return true }
        #expect(activation.activate("https://github.com/Owner/repo.name_1/pull/42"))
        #expect(count == 1)
    }

    @Test(arguments: [
        "http://github.com/owner/repository/pull/1", "file:///tmp/pull/1", "javascript:alert(1)",
        "https://github.com.evil.example/owner/repository/pull/1", "https://evil.example/owner/repository/pull/1",
        "https://user@github.com/owner/repository/pull/1", "https://github.com:443/owner/repository/pull/1",
        "https://github.com/owner/repository/pull/1?token=synthetic", "https://github.com/owner/repository/pull/1#fragment",
        "https://github.com/owner/repository/issues/1", "https://github.com/owner/repository/pull/0",
        "https://github.com/owner/repository/pull/-1", "https://github.com/owner/repository/pull/01",
        "https://github.com/owner/repository/pull/1/files", "https://github.com/owner/repository/pull/1/",
        "https://github.com/owner//pull/1", "https://github.com/owner/../pull/1",
        "https://github.com/owner/repository/pull/%31", "https://github.com/owner%2Fevil/repository/pull/1",
        "https://github.com/owner/repository/pull/99999999999999999999999999", ""
    ])
    func unsafeURLsNeverReachOpener(string: String) {
        var count = 0
        let activation = NotificationActivation { _ in count += 1; return true }
        #expect(!activation.activate(string))
        #expect(count == 0)
    }

    @Test func onlyDefaultActionsWithOwnedIdentifiersAndValidPayloadsRoute() {
        let url = "https://github.com/owner/repository/pull/1"
        #expect(NotificationActivation.responseURL(identifier: "pingit.change.hash", isDefaultAction: true, urlString: url) == url)
        #expect(NotificationActivation.responseURL(identifier: "pingit.debug.sample", isDefaultAction: true, urlString: url) == url)
        #expect(NotificationActivation.responseURL(identifier: "pingit.change.hash", isDefaultAction: false, urlString: url) == nil)
        #expect(NotificationActivation.responseURL(identifier: "foreign", isDefaultAction: true, urlString: url) == nil)
        #expect(NotificationActivation.responseURL(identifier: "pingit.change.hash", isDefaultAction: true, urlString: nil) == nil)
        #expect(NotificationActivation.responseURL(identifier: "pingit.change.hash", isDefaultAction: true, urlString: "https://evil.example") == nil)
    }
}

private actor NotificationDiscovery {
    private var authored = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [])
    func setAuthored(_ requests: [GitHubPullRequest]) {
        authored = .init(pullRequests: requests, truncationReasons: [], coverageLimitations: [])
    }
    func fetch(_ review: Bool) -> GitHubPullRequestDiscoveryResult {
        review ? .init(pullRequests: [], truncationReasons: [], coverageLimitations: []) : authored
    }
}

@MainActor
struct NotificationIntegrationTests {
    @Test func committedDraftTransitionAndRestartUseRealPhase5BCallback() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.preferences.readyForReview = true
        let event = try f.event()
        let account = GitHubAccount(id: 1, login: "octocat", avatarURL: event.url)
        let row = GitHubTokenConnection(id: UUID(), account: account, resourceOwner: "owner")
        let discovery = NotificationDiscovery()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PullRequestSnapshotStore(url: directory.appendingPathComponent("snapshot.json"))
        var time: Double = 0
        let clock = SyncClock(now: { time }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let dashboard = PullRequestDashboard(scopedCredential: { _ in "synthetic-fixture" }, clock: clock,
            changeDetector: .init(store: store), fetch: { _, _, review in await discovery.fetch(review) })
        f.coordinator.start(dashboard: dashboard)
        dashboard.setConnections([row], refresh: false)
        let pr = GitHubPullRequest(id: event.pullRequestID, number: event.number, title: "Improve tests", url: event.url,
            repository: event.repository, authorLogin: "octocat", isDraft: true, createdAt: .distantPast,
            updatedAt: .init(timeIntervalSince1970: 1), reviewStatus: .reviewRequired,
            latestReviews: .init(reviews: [], limitations: []), reviewRequests: [])
        await discovery.setAuthored([pr])
        dashboard.refresh()
        await f.wait { !dashboard.isLoading }
        #expect(!dashboard.changeDetectionStorageFailed)
        #expect(f.service.delivered.isEmpty) // Quiet initial baseline.
        let ready = GitHubPullRequest(id: pr.id, number: pr.number, title: pr.title, url: pr.url,
            repository: pr.repository, authorLogin: pr.authorLogin, isDraft: false, createdAt: pr.createdAt,
            updatedAt: .init(timeIntervalSince1970: 2), reviewStatus: pr.reviewStatus,
            latestReviews: pr.latestReviews, reviewRequests: pr.reviewRequests)
        await discovery.setAuthored([ready])
        time = 300
        dashboard.refresh(automatic: true) // No popover/view is instantiated.
        await f.wait { !dashboard.isLoading }
        await f.finish()
        #expect(f.service.delivered.map(\.title) == ["Ready for review"])
        dashboard.refresh()
        await f.wait { !dashboard.isLoading }
        await f.finish()
        #expect(f.service.delivered.count == 1)
        f.coordinator.stop()
        dashboard.shutdown()

        let restarted = PullRequestDashboard(scopedCredential: { _ in "synthetic-fixture" },
            changeDetector: .init(store: store), fetch: { _, _, review in await discovery.fetch(review) })
        // A fresh coordinator has no in-memory deduplication cache.
        let notifications = NotificationCoordinator(service: f.service, preferences: f.preferences)
        notifications.start(dashboard: restarted)
        restarted.setConnections([row], refresh: false)
        restarted.refresh()
        await f.wait { !restarted.isLoading }
        await f.wait { !notifications.isDelivering }
        #expect(f.service.delivered.count == 1)
        notifications.stop()
        restarted.shutdown()
    }

    @Test(arguments: ["sleep", "disconnect", "replacement", "shutdown", "stop"])
    func lifecycleInvalidationCancelsWaitingNotifications(reason: String) async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.service.holdStatus = true
        let event = try f.event()
        var row = GitHubTokenConnection(id: UUID(), account: .init(login: "octocat", avatarURL: event.url), resourceOwner: "owner")
        let dashboard = PullRequestDashboard(credential: { nil }, fetch: { _, _, _ in
            .init(pullRequests: [], truncationReasons: [], coverageLimitations: [])
        })
        dashboard.setConnections([row], refresh: false)
        f.coordinator.start(dashboard: dashboard)
        f.coordinator.consume([event])
        await f.wait { f.service.statusCalls == 1 }
        switch reason {
        case "sleep": dashboard.systemWillSleep()
        case "disconnect": dashboard.setConnections([], refresh: false)
        case "replacement":
            row.credentialID = UUID()
            dashboard.setConnections([row], refresh: false)
        case "shutdown": dashboard.shutdown()
        default: f.coordinator.stop()
        }
        #expect(!f.coordinator.isDelivering)
        f.service.releaseStatus(.authorized)
        // Drain a new status check after invalidation; the cancelled request cannot submit.
        await f.coordinator.refreshAuthorization()
        await Task.yield()
        #expect(f.service.attempts.isEmpty)
        f.coordinator.stop()
        #expect(dashboard.onChanges == nil && dashboard.onChangeDeliveryInvalidated == nil)
        f.coordinator.consume([try f.event(id: "after-stop")])
        #expect(!f.coordinator.isDelivering)
        dashboard.shutdown()
    }

    @Test func cancellationCannotRecallARequestAlreadySubmittedToMacOS() async throws {
        let f = NotificationFixture()
        f.preferences.enabled = true
        f.service.holdDelivery = true
        f.coordinator.consume([try f.event(), try f.event(id: "event-2")])
        await f.wait { f.service.attempts.count == 1 }
        f.coordinator.stop()
        f.service.releaseDelivery()
        await Task.yield()
        #expect(f.service.attempts.count == 1)
    }

    #if DEBUG
    @Test func debugSampleNeedsNoConnectionAndRespectsMasterAndPermission() async {
        let f = NotificationFixture()
        await f.coordinator.refreshAuthorization()
        f.coordinator.sendDebugNotification()
        #expect(f.service.attempts.isEmpty)
        f.preferences.enabled = true
        f.coordinator.sendDebugNotification()
        await f.finish()
        #expect(f.service.delivered.first?.title == "pingit test notification")
        #expect(f.service.delivered.first?.pullRequestURL == "https://github.com/octocat/Hello-World/pull/1")
        f.service.status = .denied
        await f.coordinator.refreshAuthorization()
        f.coordinator.sendDebugNotification()
        await f.finish()
        #expect(f.service.attempts.count == 1)
    }
    #endif
}
