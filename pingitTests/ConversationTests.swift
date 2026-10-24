import Foundation
import Testing

private final class ConversationMemory: @unchecked Sendable {
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

private struct ConversationFixture {
    let memory = ConversationMemory()
    let row = GitHubTokenConnection(id: UUID(), account: .init(id: 1, login: "octocat",
        avatarURL: URL(string: "https://github.com/avatar")!), resourceOwner: "owner")
    var scope: PullRequestChangeScope { .init(row)! }
    let repository = GitHubRepository(id: "R_1", nameWithOwner: "owner/private",
        url: URL(string: "https://github.com/owner/private")!)
    func pr(_ id: String = "PR_1", number: Int = 1, decision: GitHubReviewStatus = .reviewRequired,
            time: Double = 1, reviews: [GitHubPullRequestReview] = []) -> GitHubPullRequest {
        .init(id: id, number: number, title: "Secret title", url: URL(string: "https://github.com/owner/private/pull/\(number)")!,
              repository: repository, authorLogin: "octocat", isDraft: false, createdAt: .distantPast,
              updatedAt: Date(timeIntervalSince1970: time), reviewStatus: decision,
              latestReviews: .init(reviews: reviews, limitations: []), reviewRequests: [])
    }
    func comment(_ id: String = "C1", kind: PullRequestChangeEvent.Kind = .newPRComment,
                 time: Double = 150, relevant: Bool = true, bot: Bool = false, number: Int = 1) -> GitHubConversationComment {
        .init(id: id, kind: kind, publishedAt: Date(timeIntervalSince1970: time),
              url: URL(string: "https://github.com/owner/private/pull/\(number)#issuecomment-1")!,
              actorLogin: "reviewer", isBot: bot, relevant: relevant, reviewID: nil)
    }
    func input(_ sequence: UInt64, comments: [GitHubConversationComment]? = [],
               rows: [GitHubTokenConnection]? = nil, failed: Set<String> = [], truncated: Bool = false,
               decision: GitHubReviewStatus = .reviewRequired, requested: Bool = false,
               reviews: [GitHubPullRequestReview] = []) -> PullRequestChangeInput {
        let scopes = (rows ?? [row]).compactMap(PullRequestChangeScope.init)
        let time = Date(timeIntervalSince1970: Double(sequence) * 100)
        let result = GitHubPullRequestDiscoveryResult(pullRequests: [pr(decision: decision, time: Double(sequence), reviews: reviews)],
            truncationReasons: truncated ? [.pageLimit] : [], coverageLimitations: [])
        let empty = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [])
        return .init(sequence: sequence, scopes: scopes, results: Dictionary(uniqueKeysWithValues: scopes.compactMap { scope in
            if failed.contains(scope.id) { return nil }
            let observation = GitHubConversationObservation(id: "PR_1", repository: repository, number: 1,
                fingerprint: changeDigest((comments ?? []).map(\.id).sorted().joined(separator: "|")),
                verifiedAt: time, comments: comments, lastRequestedAt: requested ? time : nil)
            let conversations = GitHubConversationResult(observations: ["PR_1": observation], attemptedIDs: ["PR_1"])
            return (scope.id, .init(authored: requested ? empty : result, requested: requested ? result : empty,
                                   conversations: conversations))
        }), observedAt: time)
    }
}

struct ConversationDetectionTests {
    @Test func rotationSurvivesRestartAndPreservesCommentsBetweenTurns() async throws {
        let f = ConversationFixture()
        var detector = PullRequestChangeDetector(store: f.memory.store)
        let authored = (1...81).map { f.pr(String(format: "PR_%03d", $0), number: $0) }
        let requested = f.pr("REVIEW_1", number: 82)
        let sections = PullRequestChangeInput.Sections(
            authored: .init(pullRequests: authored, truncationReasons: [], coverageLimitations: []),
            requested: .init(pullRequests: [requested], truncationReasons: [], coverageLimitations: []))
        let requests = Dictionary(uniqueKeysWithValues: (authored + [requested]).map { ($0.id, $0) })
        var visited: Set<String> = []
        var deferredID: String?
        for sequence in 1...4 {
            let time = Date(timeIntervalSince1970: Double(sequence) * 100)
            let plan = await detector.conversationPlan(scopeID: f.scope.id, sections: sections, at: time, generation: 1)
            #expect(plan.targets.count == 40 && plan.limited)
            if sequence == 1 {
                #expect(plan.targets.first?.id == requested.id)
                deferredID = plan.targets.last?.id
            }
            visited.formUnion(plan.targets.map(\.id))
            let observations = plan.targets.map { target in
                let pr = requests[target.id]!
                let comments: [GitHubConversationComment] = sequence > 1 && target.id == deferredID
                    ? [f.comment(time: 150, number: pr.number)] : []
                return (target.id, GitHubConversationObservation(id: target.id, repository: f.repository,
                    number: pr.number, fingerprint: changeDigest(comments.map(\.id).joined()), verifiedAt: time,
                    comments: comments, lastRequestedAt: target.lastRequestedAt))
            }
            var results = sections
            results.conversations = .init(observations: Dictionary(uniqueKeysWithValues: observations),
                                          attemptedIDs: plan.targets.map(\.id), limited: true)
            let output = await detector.process(.init(sequence: UInt64(sequence), scopes: [f.scope],
                results: [f.scope.id: results], observedAt: time), generation: 1)
            #expect(!output.storageFailed)
            #expect(output.events.count == (sequence == 4 ? 1 : 0))
            if sequence == 2 {
                let saved = try #require(try f.memory.store.load()?.sources[f.scope.id])
                let deferred = try #require(deferredID)
                #expect(saved.conversations?[deferred]?.comparable == true)
                // The cursor and baselines are disk state, not an in-memory iterator.
                detector = PullRequestChangeDetector(store: f.memory.store)
            }
            if sequence == 3 { #expect(visited == Set(requests.keys)) }
        }
        #expect(try f.memory.store.load()?.sources[f.scope.id]?.conversations?.count == 82)
    }

    @Test func failedBatchDoesNotStarveTheNextBatch() async {
        let f = ConversationFixture(), detector = PullRequestChangeDetector(store: f.memory.store)
        let many = GitHubPullRequestDiscoveryResult(pullRequests: (1...81).map { f.pr("PR_\($0)", number: $0) },
            truncationReasons: [], coverageLimitations: [])
        var sections = PullRequestChangeInput.Sections(authored: many,
            requested: .init(pullRequests: [], truncationReasons: [], coverageLimitations: []))
        let first = await detector.conversationPlan(scopeID: f.scope.id, sections: sections, at: Date(), generation: 1)
        sections.conversations = .init(attemptedIDs: first.targets.map(\.id), error: .networkUnavailable)
        _ = await detector.process(.init(sequence: 1, scopes: [f.scope], results: [f.scope.id: sections],
                                         observedAt: Date()), generation: 1)
        let second = await detector.conversationPlan(scopeID: f.scope.id, sections: sections, at: Date(), generation: 1)
        #expect(Set(first.targets.map(\.id)).isDisjoint(with: second.targets.map(\.id)))
    }

    @Test func overlappingTokensShareRotationEvenAfterOneSearchFails() async throws {
        let f = ConversationFixture(), detector = PullRequestChangeDetector(store: f.memory.store)
        let second = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "second")
        let secondScope = try #require(PullRequestChangeScope(second))
        func sections(_ range: ClosedRange<Int>) -> PullRequestChangeInput.Sections {
            .init(authored: .init(pullRequests: range.map { f.pr(String(format: "PR_%03d", $0), number: $0) },
                truncationReasons: [], coverageLimitations: []),
                requested: .init(pullRequests: [], truncationReasons: [], coverageLimitations: []))
        }
        let firstSections = sections(1...81), secondSections = sections(41...121)
        let firstIDs = Set(firstSections.authored!.pullRequests.map(\.id))
        let secondIDs = Set(secondSections.authored!.pullRequests.map(\.id))
        var visited: Set<String> = []
        for sequence in 1...4 {
            var results = [f.scope.id: firstSections, secondScope.id: secondSections]
            if sequence == 2 { results.removeValue(forKey: secondScope.id) }
            let time = Date(timeIntervalSince1970: Double(sequence) * 100)
            let plans = await detector.conversationPlans(sections: results, at: time, generation: 1)
            let firstBatch = Set(plans[f.scope.id]?.targets.map(\.id) ?? [])
            let secondBatch = Set(plans[secondScope.id]?.targets.map(\.id) ?? [])
            #expect(firstBatch.union(secondBatch).count <= 40)
            if sequence != 2 {
                #expect(firstBatch.intersection(secondIDs) == secondBatch.intersection(firstIDs))
            }
            visited.formUnion(firstBatch.union(secondBatch))
            for (scope, plan) in plans {
                results[scope]?.conversations = .init(attemptedIDs: plan.targets.map(\.id), limited: plan.limited)
            }
            let output = await detector.process(.init(sequence: UInt64(sequence), scopes: [f.scope, secondScope],
                results: results, observedAt: time), generation: 1)
            #expect(!output.storageFailed)
        }
        #expect(visited == firstIDs.union(secondIDs))
    }

    @Test func initialBaselineRestartAndRepeatedSyncAreQuiet() async throws {
        let f = ConversationFixture()
        let d = PullRequestChangeDetector(store: f.memory.store)
        #expect(await d.process(f.input(1, comments: [f.comment(time: 10)]), generation: 1).events.isEmpty)
        let restarted = PullRequestChangeDetector(store: f.memory.store)
        #expect(await restarted.process(f.input(2, comments: [f.comment(time: 10)]), generation: 1).events.isEmpty)
        #expect(await restarted.process(f.input(2, comments: [f.comment(time: 10)]), generation: 1).events.isEmpty)
        #expect(try f.memory.store.load()?.version == PullRequestChangeSnapshot.schemaVersion)
    }

    @Test(arguments: [PullRequestChangeEvent.Kind.newPRComment, .newInlineReviewComment, .newReviewThreadReply])
    func newCommentKinds(kind: PullRequestChangeEvent.Kind) async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: ConversationMemory().store)
        _ = await d.process(f.input(1), generation: 1)
        let output = await d.process(f.input(2, comments: [f.comment(kind: kind)]), generation: 1)
        #expect(output.events.map(\.kind) == [kind])
        #expect(output.events.first?.signal == .conversation)
        #expect(output.events.first?.url.fragment == "issuecomment-1")
        #expect(await d.process(f.input(3, comments: [f.comment(kind: kind)]), generation: 1).events.isEmpty)
    }

    @Test func editedDeletedAndNewlyAccessibleOldCommentsDoNotNotify() async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: ConversationMemory().store)
        _ = await d.process(f.input(1, comments: [f.comment(time: 10)]), generation: 1)
        #expect(await d.process(f.input(2, comments: [f.comment(time: 150)]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(4, comments: [f.comment(), f.comment("old", time: 10)]), generation: 1).events.isEmpty)
    }

    @Test func multipleOutOfOrderTimestampsUseIDsAndCoverageFloor() async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: ConversationMemory().store)
        _ = await d.process(f.input(1), generation: 1)
        let output = await d.process(f.input(2, comments: [f.comment("later", time: 180),
            f.comment("earlier", time: 120), f.comment("historical", time: 20)]), generation: 1)
        #expect(output.events.count == 2)
        #expect(await d.process(f.input(1, comments: [f.comment("stale")]), generation: 1).events.isEmpty)
    }

    @Test func irrelevantCommentsAreConsumedWithoutEvents() async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: ConversationMemory().store)
        _ = await d.process(f.input(1), generation: 1)
        #expect(await d.process(f.input(2, comments: [f.comment(relevant: false)]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(3, comments: [f.comment(relevant: true)]), generation: 1).events.isEmpty)
    }

    @Test func tokensDeduplicateAndPartialFailureBreaksComparison() async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: ConversationMemory().store)
        let second = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "second")
        let rows = [f.row, second], secondScope = PullRequestChangeScope(second)!
        _ = await d.process(f.input(1, rows: rows), generation: 1)
        #expect(await d.process(f.input(2, comments: [f.comment()], rows: rows), generation: 1).events.count == 1)
        #expect(await d.process(f.input(3, comments: [f.comment("gap", time: 250)], rows: rows,
                                        failed: [secondScope.id]), generation: 1).events.isEmpty)
        #expect(await d.process(f.input(4, comments: [f.comment("gap", time: 250)], rows: rows), generation: 1).events.isEmpty)
    }

    @Test func addingRemovingAndReplacingTokensRebaselineQuietly() async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: ConversationMemory().store)
        _ = await d.process(f.input(1), generation: 1)
        let second = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "second")
        #expect(await d.process(f.input(2, comments: [f.comment()], rows: [f.row, second]), generation: 2).events.isEmpty)
        #expect(await d.process(f.input(3, comments: [f.comment("removed", time: 250)]), generation: 3).events.isEmpty)
        var replaced = f.row
        replaced.credentialID = UUID()
        #expect(await d.process(f.input(4, comments: [f.comment("replaced", time: 350)], rows: [replaced]), generation: 4).events.isEmpty)
    }

    @Test func truncatedOrMissingConversationCoverageRetainsTrustworthyMetadata() async throws {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, comments: [f.comment(time: 10)]), generation: 1)
        let previous = try #require(try f.memory.store.load()?.sources[f.scope.id]?.conversations?["PR_1"])
        #expect(await d.process(f.input(2, comments: [f.comment("new")], truncated: true), generation: 1).events.isEmpty)
        let after = try #require(try f.memory.store.load()?.sources[f.scope.id]?.conversations?["PR_1"])
        #expect(after.commentIDs == previous.commentIDs && after.verifiedAt == previous.verifiedAt)
        #expect(!after.comparable)
        #expect(await d.process(f.input(3, comments: [f.comment("new")]), generation: 1).events.isEmpty)
    }

    @Test func failedCommitDoesNotAdvanceOrDeliver() async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        f.memory.failWrites = true
        let failed = await d.process(f.input(2, comments: [f.comment()]), generation: 1)
        #expect(failed.storageFailed && failed.events.isEmpty)
        f.memory.failWrites = false
        #expect(await d.process(f.input(2, comments: [f.comment()]), generation: 1).events.count == 1)
    }

    @Test func versionOneMigrationPreservesReviewHistoryAndPrivacy() async throws {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        let prior = try #require(try f.memory.store.load())
        let bytes = try #require(f.memory.data)
        let decoded = try JSONSerialization.jsonObject(with: bytes)
        var object = try #require(decoded as? [String: Any])
        object["version"] = 1
        object.removeValue(forKey: "conversationScopes")
        var sources = try #require(object["sources"] as? [String: [String: Any]])
        for id in sources.keys { sources[id]?.removeValue(forKey: "conversations") }
        object["sources"] = sources
        f.memory.data = try JSONSerialization.data(withJSONObject: object)
        let migrated = try #require(try f.memory.store.load())
        #expect(migrated.version == PullRequestChangeSnapshot.schemaVersion && migrated.epoch == prior.epoch && migrated.revision == prior.revision)
        #expect(migrated.sources[f.scope.id]?.authored == prior.sources[f.scope.id]?.authored)
        let restarted = PullRequestChangeDetector(store: f.memory.store)
        let output = await restarted.process(f.input(2, comments: [f.comment()], decision: .approved), generation: 1)
        #expect(output.events.map(\.kind) == [.approved])
        let text = String(decoding: try #require(f.memory.data), as: UTF8.self)
        for privateValue in ["Secret title", "owner/private", "\"reviewer\"", "https://", "body", "test-token"] {
            #expect(!text.contains(privateValue))
        }
    }

    @Test func delayedReviewDecisionDoesNotRepeatEarlierInlineNotificationAfterRestart() async {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1), generation: 1)
        let inline = GitHubConversationComment(id: "inline", kind: .newInlineReviewComment,
            publishedAt: Date(timeIntervalSince1970: 150), url: URL(string: "https://github.com/owner/private/pull/1#discussion_r1")!,
            actorLogin: "reviewer", isBot: false, relevant: true, reviewID: "REVIEW_1", threadID: "THREAD_1")
        #expect(await d.process(f.input(2, comments: [inline]), generation: 1).events.map(\.kind) == [.newInlineReviewComment])
        let restarted = PullRequestChangeDetector(store: f.memory.store)
        let review = GitHubPullRequestReview(id: "REVIEW_1", authorLogin: "reviewer", state: .approved)
        #expect(await restarted.process(f.input(3, comments: [inline], decision: .approved, reviews: [review]), generation: 1).events.isEmpty)
    }

    @Test func retainedRequestsAreBoundedAndExpire() async throws {
        let f = ConversationFixture(), d = PullRequestChangeDetector(store: f.memory.store)
        _ = await d.process(f.input(1, requested: true), generation: 1)
        let empty = GitHubPullRequestDiscoveryResult(pullRequests: [], truncationReasons: [], coverageLimitations: [])
        let sections = PullRequestChangeInput.Sections(authored: empty, requested: empty)
        let plan = await d.conversationPlan(scopeID: f.scope.id, sections: sections,
                                          at: Date(timeIntervalSince1970: 200), generation: 1)
        #expect(plan.targets.map(\.id) == ["PR_1"] && plan.targets.first?.authored == false)
        let expired = await d.conversationPlan(scopeID: f.scope.id, sections: sections,
            at: Date(timeIntervalSince1970: 100 + GitHubConversationPlan.retention + 1), generation: 1)
        #expect(expired.targets.isEmpty)
        let many = GitHubPullRequestDiscoveryResult(pullRequests: (0..<100).map { n in
            GitHubPullRequest(id: "PR_\(n)", number: n + 1, title: "t", url: f.pr().url,
                repository: f.repository, authorLogin: "octocat", isDraft: false, createdAt: .distantPast,
                updatedAt: .distantPast, reviewStatus: nil, latestReviews: nil, reviewRequests: nil)
        }, truncationReasons: [], coverageLimitations: [])
        #expect(ConversationChangeTracking.plan(source: nil, sections: .init(authored: many, requested: empty), at: Date()).targets.count == 40)
    }
}

private final class ConversationRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private enum ConversationHTTPFixture {
    static func comment(_ id: String, login: String = "reviewer", bot: Bool = false,
                        body: String = "Hello", inline: Bool = false, reply: Bool = false,
                        published: Int = 150) -> [String: Any] {
        var result: [String: Any] = ["id": id, "publishedAt": "1970-01-01T00:\(published / 60 < 10 ? "0" : "")\(published / 60):\(published % 60 < 10 ? "0" : "")\(published % 60)Z",
            "createdAt": "1970-01-01T00:00:10Z", "body": body,
            "url": "https://github.com/owner/private/pull/1" + (inline ? "/files#discussion_r1" : "#issuecomment-1"),
            "author": ["id": "actor-\(login)", "login": login, "__typename": bot ? "Bot" : "User"]]
        if inline {
            result["state"] = "SUBMITTED"
            result["pullRequestReview"] = ["id": "REVIEW_1", "state": "COMMENTED", "submittedAt": "1970-01-01T00:02:30Z"]
            if reply { result["replyTo"] = ["id": "root"] }
        }
        return result
    }
    static func response(comments: [[String: Any]] = [], threads: [[[String: Any]]] = [],
                         truncated: Bool = false, remaining: Int = 5000, missing: Bool = false, ids: [String] = ["PR_1"]) throws -> Data {
        func connection(_ nodes: [[String: Any]]) -> [String: Any] {
            ["totalCount": nodes.count, "nodes": nodes, "pageInfo": ["hasNextPage": truncated]]
        }
        let node: [String: Any] = ["id": "PR_1", "number": 1, "state": "OPEN", "updatedAt": "1970-01-01T00:03:00Z",
            "repository": ["id": "R_1", "nameWithOwner": "owner/private", "url": "https://github.com/owner/private"],
            "comments": connection(comments), "reviewThreads": ["totalCount": threads.count,
                "pageInfo": ["hasNextPage": false], "nodes": threads.enumerated().map { n, nodes in
                    ["id": "THREAD_\(n)", "comments": connection(nodes)] as [String: Any]
                }]]
        return try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["id": "actor-octocat", "databaseId": 1, "login": "octocat"],
            "rateLimit": ["remaining": remaining, "resetAt": "2030-01-01T00:00:00Z"],
            "nodes": missing ? [NSNull()] : ids.map { id in
                var value = node
                value["id"] = id
                return value
            }]] )
    }
    static func http(_ data: Data, requests: ConversationRequests = ConversationRequests()) -> MockHTTP {
        MockHTTP { request in
            requests.record()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
    }
    static func plan(authored: Bool = true, fingerprint: String? = nil) -> GitHubConversationPlan {
        .init(targets: [.init(id: "PR_1", authored: authored, lastRequestedAt: nil, fingerprint: fingerprint)])
    }
}

struct ConversationDiscoveryTests {
    private let account = GitHubAccount(id: 1, login: "octocat", avatarURL: URL(string: "https://github.com/avatar")!)
    @Test func noTargetsDoesNotMakeRequests() async {
        let calls = ConversationRequests(), http = ConversationHTTPFixture.http(Data(), requests: calls)
        let output = await GitHubConversationDiscovery(client: http.client).fetch(plan: .init(), account: account, token: "test-token")
        #expect(output.observations.isEmpty && calls.count == 0)
    }
    @Test func unchangedProbeAvoidsBodiesAndFullConversationFetch() async throws {
        let calls = ConversationRequests()
        let http = ConversationHTTPFixture.http(try ConversationHTTPFixture.response(comments: [ConversationHTTPFixture.comment("C1")]), requests: calls)
        let discovery = GitHubConversationDiscovery(client: http.client)
        let first = await discovery.fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "test-token")
        let fingerprint = try #require(first.observations["PR_1"]?.fingerprint)
        #expect(calls.count == 2)
        let second = await discovery.fetch(plan: ConversationHTTPFixture.plan(fingerprint: fingerprint), account: account, token: "test-token")
        #expect(calls.count == 3 && second.observations["PR_1"]?.comments == nil)
        #expect(!GitHubConversationDiscovery.probeQuery.contains("body"))
    }
    @Test func selfAndActorTypeFilteringUsesGitHubIdentity() async throws {
        let http = ConversationHTTPFixture.http(try ConversationHTTPFixture.response(comments: [
            ConversationHTTPFixture.comment("self", login: "OCTOCAT"),
            ConversationHTTPFixture.comment("bot", login: "robot", bot: true),
            ConversationHTTPFixture.comment("suffix", login: "legitimate[bot]", bot: false)]))
        let output = await GitHubConversationDiscovery(client: http.client).fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "test-token")
        let comments = try #require(output.observations["PR_1"]?.comments)
        #expect(comments.map(\.id) == ["bot", "suffix"])
        #expect(comments[0].isBot && !comments[1].isBot)
    }
    @Test func directReviewerNeedsParticipationOrExplicitMention() async throws {
        let http = ConversationHTTPFixture.http(try ConversationHTTPFixture.response(comments: [
            ConversationHTTPFixture.comment("noise"), ConversationHTTPFixture.comment("mention", body: "@octocat please check")],
            threads: [[ConversationHTTPFixture.comment("mine", login: "octocat", inline: true, published: 100),
                       ConversationHTTPFixture.comment("reply", inline: true, reply: true)]]))
        let output = await GitHubConversationDiscovery(client: http.client).fetch(plan: ConversationHTTPFixture.plan(authored: false), account: account, token: "test-token")
        let comments = try #require(output.observations["PR_1"]?.comments)
        #expect(comments.filter(\.relevant).map(\.id) == ["mention", "reply"])
        #expect(comments.last?.kind == .newReviewThreadReply && comments.last?.threadID == "THREAD_0")
    }
    @Test(arguments: ["hello @octocat-other", "mail@octocat", "> @octocat", "`@octocat`", "```\n@octocat\n```"])
    func misleadingMentionsDoNotEstablishRelevance(_ body: String) {
        #expect(!GitHubConversationDiscovery.mentions(body, login: "octocat"))
    }
    @Test func inlineRootIsDistinctFromReviewSubmission() async throws {
        let http = ConversationHTTPFixture.http(try ConversationHTTPFixture.response(threads: [[ConversationHTTPFixture.comment("inline", inline: true)]]))
        let output = await GitHubConversationDiscovery(client: http.client).fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "test-token")
        #expect(output.observations["PR_1"]?.comments?.map(\.kind) == [.newInlineReviewComment])
    }
    @Test(arguments: [true, false]) func truncatedOrInaccessibleCommentsDoNotEstablishBaseline(truncated: Bool) async throws {
        let http = ConversationHTTPFixture.http(try ConversationHTTPFixture.response(comments: [ConversationHTTPFixture.comment("C1")],
            truncated: truncated, missing: !truncated))
        let output = await GitHubConversationDiscovery(client: http.client).fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "test-token")
        #expect(output.observations.isEmpty && output.limited)
    }
    @Test func primaryBudgetStopsBeforeDetailFetch() async throws {
        let calls = ConversationRequests()
        let http = ConversationHTTPFixture.http(try ConversationHTTPFixture.response(remaining: 0), requests: calls)
        let output = await GitHubConversationDiscovery(client: http.client).fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "test-token")
        #expect(output.observations.isEmpty && output.error?.retryDeadline != nil && calls.count == 1)
    }
    @Test func interruptionKeepsCompleteBatchesWithoutClaimingUnfetchedCoverage() async throws {
        let calls = ConversationRequests()
        let ids = (1...6).map { "PR_\($0)" }
        let five = Array(ids.prefix(5))
        let probe = try ConversationHTTPFixture.response(ids: five)
        let detail = try ConversationHTTPFixture.response(remaining: 0, ids: five)
        let http = MockHTTP { request in
            calls.record()
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    calls.count == 1 ? probe : detail)
        }
        let plan = GitHubConversationPlan(targets: ids.map { .init(id: $0, authored: true, lastRequestedAt: nil, fingerprint: nil) })
        let result = await GitHubConversationDiscovery(client: http.client).fetch(plan: plan, account: account, token: "test-token")
        #expect(calls.count == 2 && result.observations.count == 5 && result.attemptedIDs.count == 6)
        #expect(result.error?.retryDeadline != nil && result.observations["PR_6"] == nil)
    }
    @Test func overLimitConnectionsHaveExplicitIncompleteCoverage() async throws {
        let data = try ConversationHTTPFixture.response(comments: (1...51).map { ConversationHTTPFixture.comment("C\($0)") })
        let calls = ConversationRequests(), http = ConversationHTTPFixture.http(data, requests: calls)
        let result = await GitHubConversationDiscovery(client: http.client).fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "test-token")
        #expect(result.observations.isEmpty && result.limited && calls.count == 1)
    }
    @Test func secondaryLimitIsIsolatedFromOtherTokens() async throws {
        let http = MockHTTP(status: 429, body: "{}", headers: ["Retry-After": "60"])
        let discovery = GitHubConversationDiscovery(client: http.client)
        let output = await discovery.fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "limited-token")
        #expect(output.error?.retryDeadline != nil && output.observations.isEmpty)
        let healthy = ConversationHTTPFixture.http(try ConversationHTTPFixture.response())
        let other = await GitHubConversationDiscovery(client: healthy.client).fetch(plan: ConversationHTTPFixture.plan(), account: account, token: "healthy-token")
        #expect(other.error == nil && other.observations.count == 1)
    }
}

private actor ConversationFlight {
    let fixture = ConversationFixture()
    var sequence: UInt64 = 1
    var fail = false
    var hold = false
    var pending: CheckedContinuation<GitHubConversationResult, Never>?
    var conversationCalls = 0
    func configure(_ sequence: UInt64, fail: Bool = false, hold: Bool = false) {
        self.sequence = sequence; self.fail = fail; self.hold = hold
    }
    func sections(review: Bool) -> GitHubPullRequestDiscoveryResult {
        let input = fixture.input(sequence)
        return (review ? input.results[fixture.scope.id]?.requested : input.results[fixture.scope.id]?.authored)!
    }
    func conversations() async -> GitHubConversationResult {
        conversationCalls += 1
        if hold { return await withCheckedContinuation { pending = $0 } }
        return result()
    }
    private func result() -> GitHubConversationResult {
        if fail { return .init(attemptedIDs: ["PR_1"], error: .forbidden) }
        return fixture.input(sequence, comments: sequence == 1 ? [] : [fixture.comment()])
            .results[fixture.scope.id]!.conversations!
    }
    func waitUntilHeld() async {
        let deadline = ContinuousClock.now + .seconds(5)
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(pending != nil)
    }
    func release() { pending?.resume(returning: result()); pending = nil; hold = false }
}

@MainActor
struct ConversationRefreshTests {
    private func finish(_ dashboard: PullRequestDashboard) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while dashboard.isRefreshing, ContinuousClock.now < deadline { await Task.yield() }
        #expect(!dashboard.isRefreshing)
    }
    @Test func failedDiscoveryTokensDoNotBlockOtherConversationWorkers() async {
        let f = ConversationFixture(), flight = ConversationFlight()
        let healthy = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "healthy")
        let other = GitHubTokenConnection(id: UUID(), account: f.row.account, resourceOwner: "other")
        let dashboard = PullRequestDashboard(scopedCredential: { $0 },
            changeDetector: .init(store: f.memory.store),
            conversationFetch: { _, _, _ in await flight.conversations() },
            fetch: { _, token, review in
                guard token == healthy.storageAccount else { throw GitHubAPIError.networkUnavailable }
                return await flight.sections(review: review)
            })
        dashboard.setConnections([f.row, other, healthy], refresh: false)
        dashboard.refresh()
        await finish(dashboard)
        #expect(await flight.conversationCalls == 1)
        #expect(dashboard.sources[healthy.id]?.authored.phase == .loaded)
        #expect(dashboard.sources[f.row.id]?.authored.phase == .failed)
        dashboard.shutdown()
    }
    @Test func failedStorageShowsWarningAndSuccessfulRetryClearsIt() async {
        let f = ConversationFixture(), flight = ConversationFlight()
        var time = Date(timeIntervalSince1970: 100)
        let dashboard = PullRequestDashboard(scopedCredential: { _ in "test-token" }, now: { time },
            changeDetector: .init(store: f.memory.store),
            conversationFetch: { _, _, _ in await flight.conversations() },
            fetch: { _, _, review in await flight.sections(review: review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        await finish(dashboard)
        #expect(dashboard.changeDetectionWarning == nil)
        time = Date(timeIntervalSince1970: 200)
        await flight.configure(2)
        f.memory.failWrites = true
        dashboard.refresh()
        await finish(dashboard)
        #expect(dashboard.changeDetectionStorageFailed)
        #expect(dashboard.changeDetectionWarning?.contains("Notifications are paused") == true)
        #expect(dashboard.authored.phase == .loaded && events.isEmpty)
        time = Date(timeIntervalSince1970: 300)
        await flight.configure(3)
        f.memory.failWrites = false
        dashboard.refresh()
        await finish(dashboard)
        #expect(!dashboard.changeDetectionStorageFailed && dashboard.changeDetectionWarning == nil)
        #expect(events.map(\.kind) == [.newPRComment])
        dashboard.shutdown()
    }
    @Test func sharedRefreshCommitsCommentsAndIsolatesConversationFailures() async {
        let f = ConversationFixture(), flight = ConversationFlight()
        var time = Date(timeIntervalSince1970: 100)
        let dashboard = PullRequestDashboard(scopedCredential: { _ in "test-token" }, now: { time },
            changeDetector: .init(store: f.memory.store),
            conversationFetch: { _, _, _ in await flight.conversations() },
            fetch: { _, _, review in await flight.sections(review: review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        dashboard.refresh() // coalesces into the same flight
        await finish(dashboard)
        #expect(events.isEmpty)
        time = Date(timeIntervalSince1970: 200)
        await flight.configure(2)
        dashboard.refresh()
        await finish(dashboard)
        #expect(events.map(\.kind) == [.newPRComment])
        time = Date(timeIntervalSince1970: 300)
        await flight.configure(3, fail: true)
        dashboard.refresh()
        await finish(dashboard)
        #expect(dashboard.authored.phase == .loaded && dashboard.authored.errorMessage == nil)
        #expect(dashboard.sources[f.row.id]?.conversationWarning != nil)
        #expect(events.count == 1)
        dashboard.shutdown()
    }
    @Test func cancelledConversationCannotDeliverFromStaleFlight() async {
        let f = ConversationFixture(), flight = ConversationFlight()
        var time = Date(timeIntervalSince1970: 100)
        let dashboard = PullRequestDashboard(scopedCredential: { _ in "test-token" }, now: { time },
            changeDetector: .init(store: f.memory.store),
            conversationFetch: { _, _, _ in await flight.conversations() },
            fetch: { _, _, review in await flight.sections(review: review) })
        var events: [PullRequestChangeEvent] = []
        dashboard.onChanges = { events += $0 }
        dashboard.setConnections([f.row], refresh: false)
        dashboard.refresh()
        await finish(dashboard)
        await flight.configure(2, hold: true)
        time = Date(timeIntervalSince1970: 200)
        dashboard.refresh()
        await flight.waitUntilHeld()
        dashboard.systemWillSleep()
        await flight.release()
        await finish(dashboard)
        #expect(events.isEmpty)
        dashboard.shutdown()
    }
}
