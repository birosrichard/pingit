import Foundation
import Testing

private final class LifecycleMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var fails = false
    var data: Data? { get { lock.withLock { bytes } } set { lock.withLock { bytes = newValue } } }
    var failWrites: Bool { get { lock.withLock { fails } } set { lock.withLock { fails = newValue } } }
    var store: PullRequestSnapshotStore {
        .init(read: { self.data }, write: { data in
            try self.lock.withLock {
                if self.fails { throw PullRequestSnapshotStore.Failure.unavailable }
                self.bytes = data
            }
        })
    }
}

private struct LifecycleFixture: Sendable {
    let memory = LifecycleMemory()
    let row = GitHubTokenConnection(id: UUID(), account: .init(id: 1, login: "octocat",
        avatarURL: URL(string: "https://github.com/avatar")!), resourceOwner: "owner")
    var scope: PullRequestChangeScope { .init(row)! }
    let repository = GitHubRepository(id: "R_1", nameWithOwner: "owner/private",
        url: URL(string: "https://github.com/owner/private")!)
    func pr(_ id: String = "PR_1", time: Double = 1, draft: Bool = false) -> GitHubPullRequest {
        .init(id: id, number: 1, title: "Secret title", url: URL(string: "https://github.com/owner/private/pull/1")!,
              repository: repository, authorLogin: "octocat", isDraft: draft, createdAt: .distantPast,
              updatedAt: Date(timeIntervalSince1970: time), reviewStatus: .reviewRequired,
              latestReviews: .init(reviews: [], limitations: []), reviewRequests: [])
    }
    func observation(_ state: GitHubPullRequestState, sequence: UInt64, id: String = "PR_1") -> GitHubLifecycleObservation {
        let updated = Date(timeIntervalSince1970: sequence == 1 ? 1 : Double(sequence) * 100 - 50)
        return .init(id: id, repository: repository, number: 1,
            url: URL(string: "https://github.com/owner/private/pull/1")!, state: state, isDraft: false,
            updatedAt: updated, closedAt: state == .open ? nil : updated, mergedAt: state == .merged ? updated : nil,
            verifiedAt: Date(timeIntervalSince1970: Double(sequence) * 100))
    }
    func input(_ sequence: UInt64, state: GitHubPullRequestState? = .open,
               rows: [GitHubTokenConnection]? = nil, visible: Bool? = nil, failed: Set<String> = [],
               truncated: Bool = false, conflicting: Bool = false, requestedOnly: Bool = false) -> PullRequestChangeInput {
        let scopes = (rows ?? [row]).compactMap(PullRequestChangeScope.init)
        let show = visible ?? (state == .open)
        let result = GitHubPullRequestDiscoveryResult(pullRequests: show ? [pr(time: sequence == 1 ? 1 : Double(sequence) * 100 - 50)] : [],
            truncationReasons: truncated ? [.pageLimit] : [], coverageLimitations: conflicting ? [.conflictingMetadata] : [])
        let empty = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [])
        let owner = scopes.map(\.id).sorted().first
        let sections = Dictionary(uniqueKeysWithValues: scopes.compactMap { scope -> (String, PullRequestChangeInput.Sections)? in
            if failed.contains(scope.id) { return nil }
            let observation = state.map { self.observation($0, sequence: sequence) }
            let lifecycle: GitHubLifecycleResult? = scope.id == owner
                ? .init(observations: observation.map { ["PR_1": $0] } ?? [:], limited: state == nil) : nil
            return (scope.id, .init(authored: requestedOnly ? empty : result, requested: requestedOnly ? result : empty,
                                   lifecycles: lifecycle))
        })
        return .init(sequence: sequence, scopes: scopes, results: sections,
                     observedAt: Date(timeIntervalSince1970: Double(sequence) * 100))
    }
}

struct LifecycleDetectionTests {
    @Test(arguments: [GitHubPullRequestState.merged, .closed])
    func authoritativeTerminalTransitionSurvivesDisappearanceAndRestart(state: GitHubPullRequestState) async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: LifecycleMemory().store)
        #expect(await d.process(f.input(1), generation: 1).events.isEmpty)
        let output = await d.process(f.input(2, state: state), generation: 1)
        #expect(output.events.map(\.kind) == [state == .merged ? .prMerged : .prClosed])
        #expect(output.events.first?.signal == .lifecycle)
        #expect(output.events.first?.title == nil)
        #expect(output.events.first?.previousState == "OPEN")
        #expect(await d.process(f.input(3, state: state), generation: 1).events.isEmpty)
        let durable = PullRequestChangeDetector(store: f.memory.store)
        _ = await durable.process(f.input(1), generation: 1)
        let first = await durable.process(f.input(2, state: state), generation: 1)
        #expect(first.events.map(\.id) != output.events.map(\.id)) // independent baseline epochs
        let restart = PullRequestChangeDetector(store: f.memory.store)
        #expect(await restart.process(f.input(3, state: state), generation: 1).events.isEmpty)
        #expect(try f.memory.store.load()?.lifecycles?["PR_1"]?.state == state)
    }

    @Test func closedReopenedAndClosedAgainHaveDistinctStableEvents() async {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        let closed = await d.process(f.input(2, state: .closed), generation: 1)
        let reopened = await d.process(f.input(3), generation: 1)
        let closedAgain = await d.process(f.input(4, state: .closed), generation: 1)
        #expect(reopened.events.map(\.kind) == [.prReopened])
        #expect(closed.events.first?.id != closedAgain.events.first?.id)
    }

    @Test(arguments: [GitHubPullRequestState.merged, .closed])
    func firstTerminalObservationIsQuiet(state: GitHubPullRequestState) async {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        // Search may lag while the node is already terminal.
        #expect(await d.process(f.input(1, state: state, visible: true), generation: 1).events.isEmpty)
    }

    @Test func disappearanceMissingNodeAndRecoveryNeverInferClosure() async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        #expect(await d.process(f.input(2, state: nil, visible: false), generation: 1).events.isEmpty)
        let retained = try #require(try f.memory.store.load()?.lifecycles?["PR_1"])
        #expect(retained.state == .open && !retained.comparable)
        #expect(await d.process(f.input(3, state: .merged), generation: 1).events.isEmpty)
    }

    @Test(arguments: [true, false])
    func incompleteOrConflictingDiscoveryCannotAdvanceLifecycle(truncated: Bool) async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        #expect(await d.process(f.input(2, state: .closed, truncated: truncated, conflicting: !truncated), generation: 1).events.isEmpty)
        #expect(try f.memory.store.load()?.lifecycles?["PR_1"]?.state == .open)
        #expect(await d.process(f.input(3, state: .closed), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(4), generation: 1).events.map(\.kind) == [.prReopened])
    }

    @Test func oneLookupAndOneEventForOverlappingTokensButFailurePauses() async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        let other = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "other")
        let rows = [f.row, other]
        let plan = await d.lifecyclePlan(f.input(1, rows: rows), generation: 1)
        #expect(plan.batches.count == 1 && plan.batches.first?.ids == ["PR_1"])
        _ = await d.process(f.input(1, rows: rows), generation: 1)
        let one = await d.process(f.input(2, state: .closed, rows: rows), generation: 1)
        #expect(one.events.count == 1 && one.events.first?.sourceIDs.count == 2)
        let failed = Set([PullRequestChangeScope(other)!.id])
        #expect(await d.process(f.input(3, rows: rows, failed: failed), generation: 1).events.isEmpty)
        #expect(try f.memory.store.load()?.lifecycles?["PR_1"]?.state == .closed)
        #expect(await d.process(f.input(4, rows: rows), generation: 1).events.isEmpty)
    }

    @Test(arguments: ["add", "replace", "remove"])
    func credentialTopologyChangesQuietlyRebaseline(operation: String) async {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        let other = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "other")
        let initial = operation == "remove" ? [f.row, other] : [f.row]
        let changed = operation == "add" ? [f.row, other] : operation == "replace" ? [other] : [f.row]
        _ = await d.process(f.input(1, rows: initial), generation: 1)
        #expect(!((await d.reconcile(scopes: changed.compactMap(PullRequestChangeScope.init), generation: 2))))
        #expect(await d.process(f.input(2, state: .merged, rows: changed, visible: true), generation: 2).events.isEmpty)
    }

    @Test func requestedOnlyAndUntrackedNodesAreQuiet() async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, requestedOnly: true), generation: 1)
        #expect(await d.process(f.input(2, state: .merged, requestedOnly: true), generation: 1).events.isEmpty)
        #expect(try f.memory.store.load()?.lifecycles?.isEmpty == true)
    }

    @Test func crossAccountRefreshDoesNotReuseLifecycleState() async {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        let other = GitHubTokenConnection(id: UUID(), account: .init(id: 2, login: "someone", avatarURL: f.row.account!.avatarURL), resourceOwner: "owner")
        #expect(await d.process(f.input(2, state: .merged, rows: [other], visible: true), generation: 2).events.isEmpty)
        #expect(await d.process(f.input(3, state: .merged, rows: [f.row, other], visible: true), generation: 3).events.isEmpty)
    }

    @Test func staleSequenceGenerationAndTimestampsCannotAdvance() async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(2), generation: 2)
        #expect(await d.process(f.input(1, state: .merged), generation: 2).events.isEmpty)
        #expect(await d.process(f.input(3, state: .merged), generation: 1).events.isEmpty)
        var input = f.input(3, state: .merged)
        var sections = input.results
        sections[f.scope.id]?.lifecycles = .init(observations: ["PR_1": f.observation(.merged, sequence: 1)])
        input = .init(sequence: 3, scopes: input.scopes, results: sections, observedAt: input.observedAt)
        #expect(await d.process(input, generation: 2).events.isEmpty)
        #expect(try f.memory.store.load()?.lifecycles?["PR_1"]?.state == .open)
    }

    @Test func failedAtomicCommitEmitsNothingAndRetriesOnce() async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        let bytes = f.memory.data
        f.memory.failWrites = true
        let failed = await d.process(f.input(2, state: .merged), generation: 1)
        #expect(failed.storageFailed && failed.events.isEmpty && f.memory.data == bytes)
        f.memory.failWrites = false
        #expect(await d.process(f.input(2, state: .merged), generation: 1).events.count == 1)
        #expect(await d.process(f.input(3, state: .merged), generation: 1).events.isEmpty)
    }

    @Test(arguments: [1, 2])
    func migrationPreservesReviewsCommentsAndCoverage(version: Int) async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        var snapshot = try #require(try f.memory.store.load())
        snapshot.sources[f.scope.id]?.conversations = ["PR_1": .init(repositoryID: "R_1", number: 1,
            fingerprint: changeDigest("probe"), verifiedAt: .init(timeIntervalSince1970: 100),
            commentIDs: ["C_1"], comparable: true, reviewCommentIDs: ["REVIEW_1"])]
        snapshot.rebasingRepositories = ["R_gap"]
        let epoch = snapshot.epoch
        let encoder = JSONEncoder()
        let object = try JSONSerialization.jsonObject(with: encoder.encode(snapshot))
        var json = try #require(object as? [String: Any])
        json["version"] = version
        json.removeValue(forKey: "lifecycles")
        json.removeValue(forKey: "lifecycleScopes")
        f.memory.data = try JSONSerialization.data(withJSONObject: json)
        let migrated = try #require(try f.memory.store.load())
        #expect(migrated.version == 3 && migrated.epoch == epoch)
        #expect(migrated.sources == snapshot.sources && migrated.rebasingRepositories == snapshot.rebasingRepositories)
        #expect(migrated.lifecycles == nil)
        let restart = PullRequestChangeDetector(store: f.memory.store)
        let plan = await restart.lifecyclePlan(f.input(2, state: .merged), generation: 1)
        #expect(plan.batches.first?.ids == ["PR_1"])
        #expect(await restart.process(f.input(2, state: .merged), generation: 1).events.isEmpty)
        let stored = String(decoding: try #require(f.memory.data), as: UTF8.self)
        for secret in ["Secret title", "owner/private", "https://", "octocat", "test-token", "body"] {
            #expect(!stored.contains(secret))
        }
    }

    @Test(arguments: [GitHubPullRequestState.open, .closed, .merged])
    func retentionBoundsAndMergedPolling(state: GitHubPullRequestState) async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        _ = await d.process(f.input(2, state: state), generation: 1)
        let noSearch = f.input(3, state: nil, visible: false)
        let plan = await d.lifecyclePlan(noSearch, generation: 1)
        #expect(plan.batches.isEmpty == (state == .merged))
        // Empty but complete search prevents old authored snapshot values re-seeding expiry.
        let expired = PullRequestChangeInput(sequence: 4, scopes: noSearch.scopes, results: noSearch.results,
            observedAt: Date(timeIntervalSince1970: 200 + 31 * 86_400))
        #expect(await d.lifecyclePlan(expired, generation: 1).batches.isEmpty)
        _ = await d.process(expired, generation: 1)
        #expect(try f.memory.store.load()?.lifecycles?.isEmpty == true)
    }

    @Test func globalStorageAndBatchBounds() async throws {
        let f = LifecycleFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        let result = GitHubPullRequestDiscoveryResult(pullRequests: (0..<150).map { f.pr("PR_\($0)") },
            truncationReasons: [], coverageLimitations: [])
        let input = PullRequestChangeInput(sequence: 1, scopes: [f.scope], results: [f.scope.id: .init(authored: result)],
            observedAt: .init(timeIntervalSince1970: 100))
        let plan = await d.lifecyclePlan(input, generation: 1)
        #expect(plan.limited && plan.batches.count == 5)
        #expect(plan.batches.allSatisfy { $0.ids.count <= 20 })
        #expect(Set(plan.batches.flatMap(\.ids)).count == 100)
        _ = await d.process(input, generation: 1)
        var snapshot = try #require(try f.memory.store.load())
        #expect(snapshot.lifecycles?.count == 100)
        snapshot.lifecycles?["overflow"] = snapshot.lifecycles?.values.first
        #expect(throws: PullRequestSnapshotStore.Failure.self) { try f.memory.store.save(snapshot) }
    }
}

struct LifecycleTransportTests {
    private func response(state: String = "OPEN", author: String = "octocat", viewer: String = "octocat",
                          remaining: Int = 100, nodes: String? = nil) -> String {
        let terminal = state == "OPEN" ? "null" : "\"2026-10-22T01:00:00Z\""
        let merged = state == "MERGED" ? terminal : "null"
        let node = """
        {"__typename":"PullRequest","id":"PR_1","number":1,"url":"https://github.com/owner/private/pull/1",
         "state":"\(state)","isDraft":false,"updatedAt":"2026-10-22T01:00:00Z","closedAt":\(terminal),"mergedAt":\(merged),
         "author":{"login":"\(author)"},"repository":{"id":"R_1","nameWithOwner":"owner/private","url":"https://github.com/owner/private"}}
        """
        return """
        {"data":{"viewer":{"login":"\(viewer)","databaseId":1},"rateLimit":{"remaining":\(remaining),"resetAt":"2026-10-23T01:00:00Z"},"nodes":[\(nodes ?? node)]}}
        """
    }

    @Test(arguments: ["OPEN", "CLOSED", "MERGED"])
    func readsAuthoritativeStatesWithoutConversationOrHistoryQueries(state: String) async {
        let f = LifecycleFixture(), body = response(state: state)
        let http = MockHTTP { request in
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let stream = try #require(request.httpBodyStream)
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw GitHubAPIError.unexpectedResponse }
                    if count == 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                data = bytes
            }
            let payload = try JSONSerialization.jsonObject(with: data)
            let envelope = try #require(payload as? [String: Any])
            let text = try #require(envelope["query"] as? String)
            #expect(text.contains("PullRequestLifecycle") && text.contains("nodes(ids:"))
            #expect(!text.contains("comments(") && !text.contains("search(") && !text.contains("body"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let result = await GitHubLifecycleDiscovery(client: http.client).fetch(ids: ["PR_1"], account: f.row.account!, token: "test-token")
        #expect(result.observations["PR_1"]?.state.rawValue == state)
        #expect(!result.limited && result.error == nil)
    }

    @Test func nullNodeCannotEstablishState() async {
        let f = LifecycleFixture(), http = MockHTTP(body: response(nodes: "null"))
        let result = await GitHubLifecycleDiscovery(client: http.client).fetch(ids: ["PR_1"], account: f.row.account!, token: "test-token")
        #expect(result.observations.isEmpty && result.limited)
    }

    @Test(arguments: ["author", "viewer", "type", "state", "url", "timestamps", "duplicate"])
    func unverifiableBatchIsRejected(problem: String) async {
        let f = LifecycleFixture()
        var body = response(author: problem == "author" ? "someone" : "octocat", viewer: problem == "viewer" ? "someone" : "octocat")
        if problem == "type" { body = body.replacingOccurrences(of: "PullRequest", with: "Issue") }
        if problem == "state" { body = body.replacingOccurrences(of: "OPEN", with: "UNKNOWN") }
        if problem == "url" { body = body.replacingOccurrences(of: "https://github.com/owner/private/pull/1", with: "https://evil.example/pull/1") }
        if problem == "timestamps" { body = response(state: "CLOSED").replacingOccurrences(of: "\"closedAt\":\"2026-10-22T01:00:00Z\"", with: "\"closedAt\":null") }
        if problem == "duplicate" { body = response(nodes: "null,null") }
        let http = MockHTTP(body: body)
        let result = await GitHubLifecycleDiscovery(client: http.client).fetch(ids: ["PR_1"], account: f.row.account!, token: "test-token")
        #expect(result.observations.isEmpty && result.error != nil)
    }

    @Test(arguments: [401, 403, 429])
    func transportFailuresAndRateLimitsAreNotClosures(status: Int) async {
        let f = LifecycleFixture(), http = MockHTTP(status: status, body: "{}", headers: ["Retry-After": "60"])
        let result = await GitHubLifecycleDiscovery(client: http.client).fetch(ids: ["PR_1"], account: f.row.account!, token: "test-token")
        #expect(result.observations.isEmpty && result.error != nil)
    }

    @Test func lowPrimaryBudgetPublishesVerifiedNodeAndStopsMoreWork() async {
        let f = LifecycleFixture(), http = MockHTTP(body: response(remaining: 49))
        let result = await GitHubLifecycleDiscovery(client: http.client).fetch(ids: ["PR_1"], account: f.row.account!, token: "test-token")
        #expect(result.observations.count == 1 && result.error?.retryDeadline != nil)
    }

    @Test func partialGraphQLResponseDoesNotPublishAnyState() async {
        let f = LifecycleFixture()
        let body = response().dropLast() + ",\"errors\":[{\"message\":\"denied\"}]}"
        let http = MockHTTP(body: String(body))
        let result = await GitHubLifecycleDiscovery(client: http.client).fetch(ids: ["PR_1"], account: f.row.account!, token: "test-token")
        #expect(result.observations.isEmpty && result.error != nil)
    }

    @Test func batchSizeAndCancellationAreBounded() async {
        let f = LifecycleFixture(), http = MockHTTP(body: response())
        let discovery = GitHubLifecycleDiscovery(client: http.client)
        let oversized = await discovery.fetch(ids: (0..<21).map { "PR_\($0)" }, account: f.row.account!, token: "test-token")
        #expect(oversized.observations.isEmpty && oversized.limited)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await discovery.fetch(ids: ["PR_1"], account: f.row.account!, token: "test-token")
        }
        #expect(await task.value.observations.isEmpty)
    }
}

private actor LifecycleFlight {
    let fixture = LifecycleFixture()
    var sequence: UInt64 = 1
    var hold = false
    var pending: CheckedContinuation<GitHubLifecycleResult, Never>?
    var requests: [[String]] = []
    var failure: GitHubAPIError?
    func configure(_ sequence: UInt64, hold: Bool = false, failure: GitHubAPIError? = nil) {
        self.sequence = sequence; self.hold = hold; self.failure = failure
    }
    func sections(review: Bool) -> GitHubPullRequestDiscoveryResult {
        let result = fixture.input(sequence, state: sequence == 1 ? .open : .merged)
        return (review ? result.results[fixture.scope.id]?.requested : result.results[fixture.scope.id]?.authored)!
    }
    func lifecycle(_ ids: [String]) async -> GitHubLifecycleResult {
        requests.append(ids)
        if hold { return await withCheckedContinuation { pending = $0 } }
        return result()
    }
    private func result() -> GitHubLifecycleResult {
        if let failure { return .init(limited: true, error: failure) }
        return .init(observations: ["PR_1": fixture.observation(sequence == 1 ? .open : .merged, sequence: sequence)])
    }
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(pending != nil)
    }
    func release() { pending?.resume(returning: result()); pending = nil; hold = false }
}

@MainActor
struct LifecycleRefreshTests {
    private func finish(_ dashboard: PullRequestDashboard) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while dashboard.isRefreshing, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!dashboard.isRefreshing)
    }

    @Test func manualAndAutomaticRefreshShareDeduplicatedLifecycleFlight() async {
        let f = LifecycleFixture(), flight = LifecycleFlight()
        var time = Date(timeIntervalSince1970: 100)
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, now: { time },
            changeDetector: .init(store: f.memory.store),
            lifecycleFetch: { ids, _, _ in await flight.lifecycle(ids) },
            fetch: { _, _, review in await flight.sections(review: review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        let second = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "other")
        dashboard.setConnections([f.row, second], refresh: false)
        dashboard.refresh(automatic: true)
        dashboard.refresh() // single-flight coalescing
        await finish(dashboard)
        #expect(await flight.requests.count == 1)
        #expect(dashboard.authored.result?.pullRequests.count == 1)
        time = Date(timeIntervalSince1970: 200)
        await flight.configure(2)
        dashboard.refresh()
        await finish(dashboard)
        #expect(events.map(\.kind) == [.prMerged])
        #expect(await flight.requests.count == 2)
        #expect(dashboard.authored.result?.pullRequests.isEmpty == true)
        #expect(PullRequestInbox.allCases.count == 3)
        dashboard.shutdown()
    }

    @Test func lateCancelledLifecycleResponseCannotCommitOrDeliver() async throws {
        let f = LifecycleFixture(), flight = LifecycleFlight()
        var time = Date(timeIntervalSince1970: 100)
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, now: { time },
            changeDetector: .init(store: f.memory.store),
            lifecycleFetch: { ids, _, _ in await flight.lifecycle(ids) },
            fetch: { _, _, review in await flight.sections(review: review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        await finish(dashboard)
        time = Date(timeIntervalSince1970: 200)
        await flight.configure(2, hold: true)
        dashboard.refresh()
        await flight.waitUntilHeld()
        dashboard.systemWillSleep()
        await flight.release()
        time = Date(timeIntervalSince1970: 300)
        await flight.configure(3)
        dashboard.systemDidWake()
        dashboard.refresh() // queues after the cancelled worker drains
        let deadline = ContinuousClock.now + .seconds(5)
        while await flight.requests.count < 3, ContinuousClock.now < deadline { await Task.yield() }
        await finish(dashboard)
        #expect(events.map(\.kind) == [.prMerged])
        #expect(events.first?.observedAt == time)
        #expect(try f.memory.store.load()?.lifecycles?["PR_1"]?.state == .merged)
        dashboard.shutdown()
    }

    @Test func lifecycleRateLimitUsesExistingSchedulerAndKeepsDashboardHealthy() async {
        let f = LifecycleFixture(), flight = LifecycleFlight()
        await flight.configure(1, failure: .rateLimitedUntil(Date(timeIntervalSince1970: 1000)))
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, now: { .init(timeIntervalSince1970: 100) },
            changeDetector: .init(store: f.memory.store),
            lifecycleFetch: { ids, _, _ in await flight.lifecycle(ids) },
            fetch: { _, _, review in await flight.sections(review: review) })
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        await finish(dashboard)
        #expect(dashboard.authored.phase == .loaded)
        #expect(dashboard.sources[f.row.id]?.lifecycleWarning != nil)
        dashboard.refresh()
        #expect(!dashboard.isRefreshing)
        #expect(await flight.requests.count == 1)
        dashboard.shutdown()
    }
}
