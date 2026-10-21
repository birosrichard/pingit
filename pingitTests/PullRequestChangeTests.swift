import Foundation
import Testing

private final class SnapshotMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    private var failure = false
    private var writes = 0
    var data: Data? { get { lock.withLock { bytes } } set { lock.withLock { bytes = newValue } } }
    var failWrites: Bool { get { lock.withLock { failure } } set { lock.withLock { failure = newValue } } }
    var writeCount: Int { lock.withLock { writes } }
    var store: PullRequestSnapshotStore {
        .init(read: { self.data }, write: { data in
            try self.lock.withLock {
                if self.failure { throw PullRequestSnapshotStore.Failure.unavailable }
                self.bytes = data
                self.writes += 1
            }
        })
    }
}

private struct ChangesFixture {
    let memory = SnapshotMemory()
    let row = GitHubTokenConnection(id: UUID(), account: .init(id: 1, login: "octocat", avatarURL: URL(string: "https://github.com/avatar")!), resourceOwner: "owner")
    var scope: PullRequestChangeScope { .init(row)! }
    func pr(_ id: String = "PR_1", repo: String = "R_1", time: Double = 1,
            draft: Bool = false, decision: GitHubReviewStatus? = .reviewRequired,
            reviews: [GitHubPullRequestReview] = [], limitations: Set<GitHubLatestReviews.Limitation> = []) -> GitHubPullRequest {
        .init(id: id, number: id == "PR_1" ? 1 : 2, title: "Private title",
              url: URL(string: "https://github.com/owner/private/pull/\(id == "PR_1" ? 1 : 2)")!,
              repository: .init(id: repo, nameWithOwner: "owner/private", url: URL(string: "https://github.com/owner/private")!),
              authorLogin: "octocat", isDraft: draft, createdAt: .distantPast, updatedAt: .init(timeIntervalSince1970: time),
              reviewStatus: decision, latestReviews: .init(reviews: reviews, limitations: limitations), reviewRequests: [])
    }
    func review(_ state: GitHubPullRequestReview.State, id: String = "review1", login: String = "reviewer") -> GitHubPullRequestReview {
        .init(id: id, authorLogin: login, state: state)
    }
    func result(_ prs: [GitHubPullRequest], truncated: Bool = false,
                conflicting: Bool = false) -> GitHubPullRequestDiscoveryResult {
        .init(pullRequests: prs, truncationReasons: truncated ? [.resultLimit] : [],
              coverageLimitations: conflicting ? [.tokenVisibility, .conflictingMetadata] : [.tokenVisibility])
    }
    func input(_ sequence: UInt64, authored: [GitHubPullRequest] = [], requested: [GitHubPullRequest] = [],
               rows: [GitHubTokenConnection]? = nil, truncated: Bool = false) -> PullRequestChangeInput {
        let scopes = (rows ?? [row]).compactMap(PullRequestChangeScope.init)
        return .init(sequence: sequence, scopes: scopes, results: Dictionary(uniqueKeysWithValues: scopes.map {
            ($0.id, .init(authored: result(authored, truncated: truncated), requested: result(requested, truncated: truncated)))
        }), observedAt: .init(timeIntervalSince1970: Double(sequence)))
    }
}

struct PullRequestChangeTests {
    @Test func firstSyncRestartAndIdenticalSnapshotsAreQuiet() async throws {
        let f = ChangesFixture(), detector = PullRequestChangeDetector(store: fMemory())
        #expect(await detector.process(f.input(1, authored: [f.pr()], requested: [f.pr("PR_2")]), generation: 1).events.isEmpty)
        let d = PullRequestChangeDetector(store: f.memory.store)
        #expect(await d.process(f.input(1, authored: [f.pr(draft: true)]), generation: 1).events.isEmpty)
        let writes = f.memory.writeCount
        #expect(await d.process(f.input(2, authored: [f.pr(draft: true)]), generation: 1).events.isEmpty)
        #expect(f.memory.writeCount == writes)
        let restarted = PullRequestChangeDetector(store: f.memory.store)
        let changed = await restarted.process(f.input(1, authored: [f.pr(time: 2, draft: false)]), generation: 1)
        #expect(changed.events.map(\.kind) == [.readyForReview])
        let again = PullRequestChangeDetector(store: f.memory.store)
        #expect(await again.process(f.input(1, authored: [f.pr(time: 2)]), generation: 1).events.isEmpty)
    }

    @Test(arguments: [Data("corrupt".utf8), Data("{\"version\":999}".utf8)])
    func damagedOrFutureSchemaEstablishesBaseline(data: Data) async {
        let f = ChangesFixture()
        f.memory.data = data
        let d = PullRequestChangeDetector(store: f.memory.store)
        let output = await d.process(f.input(1, authored: [f.pr(decision: .approved)]), generation: 1)
        #expect(output.events.isEmpty && !output.storageFailed)
        #expect(f.memory.writeCount == 1)
    }

    @Test func directRequestAddedAndRemovedWithRepositoryEvidence() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr("witness")]), generation: 1)
        let added = await d.process(f.input(2, authored: [f.pr("witness")], requested: [f.pr()]), generation: 1)
        #expect(added.events.map(\.kind) == [.reviewRequested])
        let removed = await d.process(f.input(3, authored: [f.pr("witness")]), generation: 1)
        #expect(removed.events.map(\.kind) == [.reviewRequestRemoved])
        #expect(removed.events.first?.title == nil)
        #expect(removed.events.first?.url.absoluteString == "https://github.com/owner/private/pull/1")
        #expect(await d.process(f.input(4, authored: [f.pr("witness")]), generation: 1).events.isEmpty)
    }

    @Test func noRepositoryEvidenceRetainsRequestEvenAfterRestart() async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, requested: [f.pr()]), generation: 1)
        #expect(await d.process(f.input(2), generation: 1).events.isEmpty)
        let own = PullRequestChangeDetector(store: f.memory.store)
        _ = await own.process(f.input(1, requested: [f.pr()]), generation: 1)
        _ = await own.process(f.input(2), generation: 1)
        let saved = try #require(try f.memory.store.load())
        #expect(saved.sources[f.scope.id]?.requested?["PR_1"] != nil)
        let restart = PullRequestChangeDetector(store: f.memory.store)
        #expect(await restart.process(f.input(1, requested: [f.pr()]), generation: 1).events.isEmpty)
    }

    @Test(arguments: [false, true])
    func failuresAndTruncationNeverRemoveOrReplaceBaseline(truncated: Bool) async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)], requested: [f.pr("PR_2")]), generation: 1)
        let input = truncated ? f.input(2, truncated: true) : PullRequestChangeInput(
            sequence: 2, scopes: [f.scope], results: [:], observedAt: Date())
        #expect(await d.process(input, generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr(draft: true)], requested: [f.pr("PR_2")]), generation: 1).events.isEmpty)
    }

    @Test func newlyVisibleRepositoryAndNewReadyPullRequestAreBaselines() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr()]), generation: 1)
        #expect(await d.process(f.input(2, authored: [f.pr(), f.pr("ready", time: 2)],
                                        requested: [f.pr("request", repo: "hidden")]), generation: 1).events.isEmpty)
    }

    @Test func tokensDeduplicateAndConfigurationChangesDoNotBecomeActivity() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        let second = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "second")
        let rows = [f.row, second]
        _ = await d.process(f.input(1, authored: [f.pr("witness")], rows: rows), generation: 1)
        let added = await d.process(f.input(2, authored: [f.pr("witness")], requested: [f.pr()], rows: rows), generation: 1)
        #expect(added.events.count == 1)
        let third = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "third")
        #expect(await d.process(f.input(3, authored: [f.pr("witness")], requested: [f.pr(), f.pr("hidden")],
                                        rows: rows + [third]), generation: 2).events.isEmpty)
        #expect(await d.process(f.input(4, authored: [f.pr("witness")], rows: [f.row]), generation: 3).events.isEmpty)
        var replacement = f.row
        replacement.credentialID = UUID()
        #expect(await d.process(f.input(5, authored: [f.pr(decision: .approved)], requested: [f.pr()], rows: [replacement]), generation: 4).events.isEmpty)
    }

    @Test func addingTokenDoesNotResetUnrelatedDraftHistory() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)]), generation: 1)
        let extra = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "other")
        var results = f.input(2, authored: [f.pr(time: 2)], rows: [f.row, extra]).results
        results[extra.storageAccount] = .init(authored: f.result([f.pr("unrelated", repo: "other")]), requested: f.result([]))
        let input = PullRequestChangeInput(sequence: 2, scopes: [f.scope, .init(extra)!], results: results, observedAt: Date())
        #expect(await d.process(input, generation: 2).events.map(\.kind) == [.readyForReview])
    }

    @Test(arguments: [GitHubReviewStatus.approved, .changesRequested])
    func authoritativeAndReviewerSignalEmitOneEvent(decision: GitHubReviewStatus) async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr()]), generation: 1)
        let review = f.review(decision == .approved ? .approved : .changesRequested)
        let output = await d.process(f.input(2, authored: [f.pr(time: 2, decision: decision, reviews: [review])]), generation: 1)
        #expect(output.events.count == 1)
        #expect(output.events.first?.signal == .decision)
        #expect(output.events.first?.kind == (decision == .approved ? .approved : .changesRequested))
    }

    @Test(arguments: [GitHubPullRequestReview.State.approved, .changesRequested])
    func completeIndividualReviewTransitions(state: GitHubPullRequestReview.State) async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr(decision: .unknown, reviews: [f.review(.commented)])]), generation: 1)
        let output = await d.process(f.input(2, authored: [f.pr(time: 2, decision: .unknown, reviews: [f.review(state, id: "new")])]), generation: 1)
        #expect(output.events.count == 1 && output.events.first?.signal == .reviewer)
        #expect(output.events.first?.actorLogin == "reviewer")
    }

    @Test func existingBotApprovalAndDismissedReviewsAreQuiet() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        let bot = f.review(.approved, login: "robot[bot]")
        _ = await d.process(f.input(1, authored: [f.pr(reviews: [bot])]), generation: 1)
        #expect(await d.process(f.input(2, authored: [f.pr(time: 2, reviews: [bot])]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 3, reviews: [f.review(.dismissed, id: "dismissed")])]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(4, authored: [f.pr(time: 4, reviews: [f.review(.approved, id: "restore")])]), generation: 1).events.isEmpty)
    }

    @Test func unknownDecisionAndReviewEnrichmentAreQuiet() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr(decision: .unknown, limitations: [.unavailable])]), generation: 1)
        let enriched = f.pr(time: 2, decision: .approved, reviews: [f.review(.approved)])
        #expect(await d.process(f.input(2, authored: [enriched]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 3, decision: .approved, reviews: [f.review(.approved)])]), generation: 1).events.isEmpty)
    }

    @Test func incompleteDetailsKeepTrustedStateAndRebaselineOnRecovery() async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, authored: [f.pr(reviews: [f.review(.commented)])]), generation: 1)
        _ = await d.process(f.input(2, authored: [f.pr(time: 2, reviews: [], limitations: [.reviewerLimit])]), generation: 1)
        let snapshot = try #require(try f.memory.store.load())
        let pr = try #require(snapshot.sources[f.scope.id]?.authored?["PR_1"])
        #expect(!pr.reviewsComplete && pr.reviewers?.count == 1)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 3, reviews: [f.review(.approved, id: "new")])]), generation: 1).events.isEmpty)
    }

    @Test func conflictingTokensAndStaggeredRefreshesNeverDuplicateReviews() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        let second = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "second")
        let rows = [f.row, second]
        _ = await d.process(f.input(1, authored: [f.pr()], rows: rows), generation: 1)
        var changed = f.input(2, authored: [f.pr(time: 2, decision: .approved)], rows: rows)
        let oneSource = PullRequestChangeInput(sequence: 2, scopes: changed.scopes,
            results: [f.scope.id: changed.results[f.scope.id]!], observedAt: Date())
        #expect(await d.process(oneSource, generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 2, decision: .approved)], rows: rows), generation: 1).events.isEmpty)
        var results = f.input(4, authored: [f.pr(time: 3, decision: .changesRequested)], rows: rows).results
        results[second.storageAccount] = .init(authored: f.result([f.pr(time: 3, decision: .approved)]), requested: f.result([]))
        changed = .init(sequence: 4, scopes: changed.scopes, results: results, observedAt: Date())
        #expect(await d.process(changed, generation: 1).events.isEmpty)
        #expect(await d.process(f.input(5, authored: [f.pr(time: 4, decision: .changesRequested)], rows: rows), generation: 1).events.isEmpty)
    }

    @Test func reviewerApprovalCanBecomeChangesRequestedWithoutOverallDecision() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr(decision: .unknown, reviews: [f.review(.approved)])]), generation: 1)
        let output = await d.process(f.input(2, authored: [f.pr(time: 2, decision: .unknown,
            reviews: [f.review(.changesRequested, id: "new-opinion")])]), generation: 1)
        #expect(output.events.map(\.kind) == [.changesRequested])
        #expect(output.events.first?.previousState == "approved")
    }

    @Test func conflictingDecisionsSuppressEvenMatchingIndividualApproval() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        let second = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "second")
        let rows = [f.row, second]
        _ = await d.process(f.input(1, authored: [f.pr()], rows: rows), generation: 1)
        let approved = f.pr(time: 2, decision: .approved, reviews: [f.review(.approved)])
        var results = f.input(2, authored: [approved], rows: rows).results
        results[second.storageAccount] = .init(authored: f.result([f.pr(time: 2, decision: .changesRequested,
            reviews: [f.review(.approved)])]), requested: f.result([]))
        #expect(await d.process(.init(sequence: 2, scopes: rows.compactMap(PullRequestChangeScope.init),
            results: results, observedAt: Date()), generation: 1).events.isEmpty)
    }

    @Test func replacementMetadataEnrichmentAndFailedDuplicateSourceStayQuiet() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr()], requested: [f.pr("PR_2")]), generation: 1)
        let added = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "added")
        var results = f.input(2, authored: [f.pr(time: 2, decision: .approved)], requested: [f.pr("PR_2")], rows: [f.row, added]).results
        results[f.scope.id] = nil
        #expect(await d.process(.init(sequence: 2, scopes: [f.scope, .init(added)!], results: results,
            observedAt: Date()), generation: 2).events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 2, decision: .approved)], requested: [f.pr("PR_2")],
            rows: [f.row, added]), generation: 2).events.isEmpty)
    }

    @Test func absentRepositoryRetainsAuthoredAndRequestedState() async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)], requested: [f.pr("PR_2")]), generation: 1)
        let bytes = f.memory.data
        #expect(await d.process(f.input(2), generation: 1).events.isEmpty)
        #expect(f.memory.data == bytes)
        let snapshot = try #require(try f.memory.store.load())
        #expect(snapshot.sources[f.scope.id]?.authored?["PR_1"]?.isDraft == true)
        #expect(snapshot.sources[f.scope.id]?.requested?["PR_2"] != nil)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 3)], requested: [f.pr("PR_2")]), generation: 1).events.map(\.kind) == [.readyForReview])
    }

    @Test func firstIndividualApprovalRequiresComparableCompleteEmptyReviews() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr(decision: .unknown)]), generation: 1)
        let output = await d.process(f.input(2, authored: [f.pr(time: 2, decision: .unknown,
            reviews: [f.review(.approved)])]), generation: 1)
        #expect(output.events.map(\.kind) == [.approved])
        #expect(output.events.first?.signal == .reviewer)
    }

    @Test func cancellationDuringCommitConsumesWithoutDeliveringOrReplaying() async {
        let f = ChangesFixture()
        let store = PullRequestSnapshotStore(read: { f.memory.data }, write: { data in
            try f.memory.store.write(data)
            withUnsafeCurrentTask { $0?.cancel() }
        })
        let d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)]), generation: 1)
        let committing = PullRequestChangeDetector(store: store)
        let output = await Task { await committing.process(f.input(1, authored: [f.pr(time: 2)]), generation: 1) }.value
        #expect(output.events.isEmpty && !output.storageFailed)
        let restart = PullRequestChangeDetector(store: f.memory.store)
        #expect(await restart.process(f.input(1, authored: [f.pr(time: 2)]), generation: 1).events.isEmpty)
    }

    @Test func validFutureVersionAndInvalidBoundsResetSafely() async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)]), generation: 1)
        var snapshot = try #require(try f.memory.store.load())
        snapshot.version = 999
        f.memory.data = try JSONEncoder().encode(snapshot)
        let future = PullRequestChangeDetector(store: f.memory.store)
        #expect(await future.process(f.input(1, authored: [f.pr(time: 2)]), generation: 1).events.isEmpty)
        snapshot.version = 1
        snapshot.identity = "invalid"
        f.memory.data = try JSONEncoder().encode(snapshot)
        #expect(try f.memory.store.load() == nil)
        let tooBig = PullRequestSnapshotStore(read: { Data(repeating: 0, count: PullRequestSnapshotStore.maximumBytes + 1) },
                                             write: { _ in Issue.record("Oversized input must not be overwritten") })
        #expect(await PullRequestChangeDetector(store: tooBig).process(f.input(1), generation: 1).storageFailed)
    }

    @Test func sameTimestampEnrichmentSupersededReviewAndReadyToDraftAreQuiet() async {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: fMemory())
        _ = await d.process(f.input(1, authored: [f.pr()]), generation: 1)
        #expect(await d.process(f.input(2, authored: [f.pr(reviews: [f.review(.approved)])]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 2, draft: true, reviews: [f.review(.commented, id: "new")])]), generation: 1).events.isEmpty)
    }

    @Test func failureDoesNotDeliverOrAdvanceAndRetryCommitsOnce() async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)]), generation: 1)
        let bytes = f.memory.data
        f.memory.failWrites = true
        let input = f.input(2, authored: [f.pr(time: 2)])
        let failed = await d.process(input, generation: 1)
        #expect(failed.events.isEmpty && failed.storageFailed && f.memory.data == bytes)
        f.memory.failWrites = false
        let retry = await d.process(input, generation: 1)
        #expect(retry.events.count == 1)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 2)]), generation: 1).events.isEmpty)
        let restart = PullRequestChangeDetector(store: f.memory.store)
        #expect(await restart.process(f.input(1, authored: [f.pr(time: 2)]), generation: 1).events.isEmpty)
    }

    @Test func cancellationAndOutOfOrderCompletionDoNotAdvance() async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)]), generation: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await d.process(f.input(2, authored: [f.pr(time: 2)]), generation: 1)
        }
        #expect(await task.value.events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr(time: 3)]), generation: 1).events.count == 1)
        let bytes = f.memory.data
        #expect(await d.process(f.input(2, authored: [f.pr(time: 2, draft: true)]), generation: 1).events.isEmpty)
        #expect(f.memory.data == bytes)
        #expect(await d.process(f.input(4, authored: [f.pr(time: 1, draft: true)]), generation: 1).events.isEmpty)
    }

    @Test func disconnectReconnectAndIdentityIsolation() async throws {
        let f = ChangesFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, authored: [f.pr(draft: true)]), generation: 1)
        await d.reconcile(scopes: [], generation: 2)
        #expect(try f.memory.store.load()?.sources.isEmpty == true)
        #expect(await d.process(f.input(2, authored: [f.pr()]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3, authored: [f.pr()]), generation: 3).events.isEmpty)
        var other = f.row
        other.credentialID = UUID()
        other.account = .init(id: 2, login: "other", avatarURL: f.row.account!.avatarURL)
        #expect(await d.process(f.input(4, authored: [f.pr(time: 4, decision: .approved)], rows: [other]), generation: 4).events.isEmpty)
        #expect(await d.process(f.input(5, authored: [f.pr(time: 5)], rows: [f.row, other]), generation: 5).events.isEmpty)
    }

    @Test func paginationOrderingAndEventIDsAreStable() async {
        let f = ChangesFixture(), a = PullRequestChangeDetector(store: fMemory()), b = PullRequestChangeDetector(store: fMemory())
        for d in [a, b] { _ = await d.process(f.input(1, authored: [f.pr(draft: true), f.pr("PR_2", draft: true)]), generation: 1) }
        let first = await a.process(f.input(2, authored: [f.pr(time: 2), f.pr("PR_2", time: 2)]), generation: 1)
        let second = await b.process(f.input(2, authored: [f.pr("PR_2", time: 2), f.pr(time: 2)]), generation: 1)
        #expect(first.events.map(\.id) == second.events.map(\.id))
        #expect(Set(first.events.map(\.id)).count == 2)
    }

    @Test func storageRoundTripPrivacyPermissionsBoundsAndAtomicFailure() async throws {
        let f = ChangesFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json"), store = PullRequestSnapshotStore(url: directory.appendingPathComponent("snapshot.json"))
        let d = PullRequestChangeDetector(store: store)
        _ = await d.process(f.input(1, authored: [f.pr(reviews: [f.review(.approved)])]), generation: 1)
        let orphan = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try Data("interrupted write".utf8).write(to: orphan)
        let saved = try #require(try store.load())
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(saved == (try JSONDecoder().decode(PullRequestChangeSnapshot.self, from: JSONEncoder().encode(saved))))
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in ["Private title", "owner/private", "reviewer", "https://", "token", "body", "diff"] {
            // Schema keys 'reviewers' are allowed; the actual login must be absent.
            if forbidden == "reviewer" { #expect(!text.contains("\"reviewer\"")) }
            else { #expect(!text.contains(forbidden)) }
        }
        #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let bytes = try Data(contentsOf: url)
        let failed = PullRequestSnapshotStore(url: url.appendingPathComponent("impossible.json"))
        #expect(throws: (any Error).self) { try failed.save(saved) }
        #expect(try Data(contentsOf: url) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["snapshot.json"])
        var oversized = saved
        let pr = PullRequestChangeSnapshot.PullRequest(f.pr())
        oversized.sources = ["source": .init(authored: Dictionary(uniqueKeysWithValues: (0...PullRequestSnapshotStore.maximumEntries).map { ("id\($0)", pr) }))]
        #expect(throws: (any Error).self) { try store.save(oversized) }
        #expect(try Data(contentsOf: url) == bytes)
        let unreadable = PullRequestSnapshotStore(read: { throw PullRequestSnapshotStore.Failure.unavailable }, write: { _ in Issue.record("Must not overwrite unreadable state") })
        #expect(await PullRequestChangeDetector(store: unreadable).process(f.input(1), generation: 1).storageFailed)
    }
}

private func fMemory() -> PullRequestSnapshotStore { SnapshotMemory().store }

// Completion is controlled independently of cancellation to exercise the real coordinator guards.
private actor ChangeDiscovery {
    private var requests: [(Bool, CheckedContinuation<GitHubPullRequestDiscoveryResult, any Error>)] = []
    private(set) var calls = 0
    func fetch(_ review: Bool) async throws -> GitHubPullRequestDiscoveryResult {
        calls += 1
        return try await withCheckedThrowingContinuation { requests.append((review, $0)) }
    }
    func waitForCalls(_ count: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while calls < count, ContinuousClock.now < deadline { await Task.yield() }
        #expect(calls == count)
    }
    func resolve(authored: GitHubPullRequestDiscoveryResult, requested: GitHubPullRequestDiscoveryResult,
                 failRequested: Bool = false) {
        let pending = requests
        requests = []
        for (review, continuation) in pending {
            if review && failRequested { continuation.resume(throwing: GitHubAPIError.networkUnavailable) }
            else { continuation.resume(returning: review ? requested : authored) }
        }
    }
}

@MainActor
struct ChangeRefreshIntegrationTests {
    private func finish(_ dashboard: PullRequestDashboard) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while dashboard.isLoading, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!dashboard.isLoading)
    }

    @Test func coalescedManualPopoverAndAutomaticRefreshCommitOnce() async {
        let f = ChangesFixture(), service = ChangeDiscovery()
        var time: Double = 0
        let clock = SyncClock(now: { time }, sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, clock: clock,
            changeDetector: .init(store: f.memory.store), fetch: { _, _, review in try await service.fetch(review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        dashboard.refresh()
        dashboard.loadIfNeeded()
        await service.waitForCalls(2)
        await service.resolve(authored: f.result([f.pr(draft: true)]), requested: f.result([]))
        await finish(dashboard)
        #expect(events.isEmpty)
        time = 300
        dashboard.refresh(automatic: true)
        dashboard.refresh()
        await service.waitForCalls(4)
        await service.resolve(authored: f.result([f.pr(time: 2)]), requested: f.result([]))
        await finish(dashboard)
        #expect(events.map(\.kind) == [.readyForReview])
        #expect(f.memory.writeCount == 2)
        dashboard.refresh()
        await service.waitForCalls(6)
        await service.resolve(authored: f.result([f.pr(time: 2)]), requested: f.result([]))
        await finish(dashboard)
        #expect(events.count == 1 && f.memory.writeCount == 2)
        dashboard.shutdown()
    }

    @Test(arguments: [false, true])
    func lateDiscoveryAfterSleepOrDisconnectNeverDelivers(disconnect: Bool) async {
        let f = ChangesFixture(), service = ChangeDiscovery()
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, changeDetector: .init(store: f.memory.store),
            fetch: { _, _, review in try await service.fetch(review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        await service.waitForCalls(2)
        await service.resolve(authored: f.result([f.pr(draft: true)]), requested: f.result([]))
        await finish(dashboard)
        dashboard.refresh()
        await service.waitForCalls(4)
        if disconnect { dashboard.setConnections([], refresh: false) }
        else { dashboard.systemWillSleep() }
        await service.resolve(authored: f.result([f.pr(time: 2)]), requested: f.result([]))
        // Rejoining waits for old workers to drain before making the new request.
        if disconnect { dashboard.setConnections([f.row], refresh: false) }
        else { dashboard.systemDidWake() }
        dashboard.refresh()
        await service.waitForCalls(6)
        await service.resolve(authored: f.result([f.pr(time: 3)]), requested: f.result([]))
        await finish(dashboard)
        #expect(events.count == (disconnect ? 0 : 1))
        #expect(events.allSatisfy { $0.kind == .readyForReview })
        dashboard.shutdown()
    }

    @Test func partialFlightUsesOnlyFreshSuccessfulSectionsAndReportsStorageFailure() async {
        let f = ChangesFixture(), service = ChangeDiscovery()
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, changeDetector: .init(store: f.memory.store),
            fetch: { _, _, review in try await service.fetch(review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        await service.waitForCalls(2)
        await service.resolve(authored: f.result([f.pr("witness", draft: true)]), requested: f.result([f.pr()]))
        await finish(dashboard)
        dashboard.refresh()
        await service.waitForCalls(4)
        await service.resolve(authored: f.result([f.pr("witness", time: 2)]), requested: f.result([]), failRequested: true)
        await finish(dashboard)
        #expect(events.map(\.kind) == [.readyForReview])
        #expect(dashboard.reviews.phase == .failed)
        f.memory.failWrites = true
        dashboard.refresh()
        await service.waitForCalls(6)
        await service.resolve(authored: f.result([f.pr("witness", time: 3)]), requested: f.result([]))
        await finish(dashboard)
        #expect(dashboard.changeDetectionStorageFailed && events.count == 1)
        f.memory.failWrites = false
        dashboard.refresh()
        await service.waitForCalls(8)
        await service.resolve(authored: f.result([f.pr("witness", time: 3)]), requested: f.result([]))
        await finish(dashboard)
        #expect(!dashboard.changeDetectionStorageFailed)
        #expect(events.map(\.kind) == [.readyForReview, .reviewRequestRemoved])
        dashboard.shutdown()
    }

    @Test func replacingConsumerDoesNotReplayEvents() async {
        let f = ChangesFixture(), service = ChangeDiscovery()
        let dashboard = PullRequestDashboard(scopedCredential: { $0 }, changeDetector: .init(store: f.memory.store),
            fetch: { _, _, review in try await service.fetch(review) })
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        await service.waitForCalls(2)
        await service.resolve(authored: f.result([f.pr(draft: true)]), requested: f.result([]))
        await finish(dashboard)
        var first = 0, second = 0
        dashboard.onChanges = { first += $0.count }
        dashboard.onChanges = { second += $0.count }
        dashboard.refresh()
        await service.waitForCalls(4)
        await service.resolve(authored: f.result([f.pr(time: 2)]), requested: f.result([]))
        await finish(dashboard)
        #expect(first == 0 && second == 1)
        dashboard.onChanges = { first += $0.count }
        #expect(first == 0)
        dashboard.shutdown()
    }
}
