import Foundation

// No suspension inside compare/commit: one actor serializes disk I/O and baseline advancement.
actor PullRequestChangeDetector {
    struct Output: Sendable {
        var events: [PullRequestChangeEvent] = []
        var storageFailed = false
    }
    private let store: PullRequestSnapshotStore
    private var baseline: PullRequestChangeSnapshot?
    private var loaded = false
    private var generation: UInt64 = 0
    private var lastSequence: UInt64 = 0

    init(store: PullRequestSnapshotStore = .init()) { self.store = store }

    @discardableResult
    func reconcile(scopes: [PullRequestChangeScope], generation: UInt64) -> Bool {
        guard generation >= self.generation else { return false }
        self.generation = generation
        do {
            try load()
            guard let old = baseline else { return false }
            let next = reconciled(old, scopes: scopes)
            if old != next { try store.save(next); baseline = next }
            return false
        } catch { return true }
    }

    func process(_ input: PullRequestChangeInput, generation: UInt64) -> Output {
        guard generation >= self.generation, input.sequence > lastSequence, !Task.isCancelled else { return Output() }
        self.generation = generation
        do {
            try load()
            let identities = Set(input.scopes.map(\.identity))
            guard identities.count == 1, let identity = identities.first else { return Output() }
            let old = reconciled(baseline ?? .init(identity: identity), scopes: input.scopes)
            var next = old
            for scope in input.scopes {
                guard let sections = input.results[scope.id] else { continue }
                var source = next.sources[scope.id] ?? .init()
                if let result = complete(sections.authored) {
                    source.authored = projected(result, previous: source.authored)
                }
                if let result = complete(sections.requested) {
                    var requested = projected(result, previous: source.requested)
                    let visible = repositoryIDs(sections)
                    // A successful empty search cannot prove access to a disappeared repository.
                    for (id, pr) in source.requested ?? [:] where requested[id] == nil && !visible.contains(pr.repositoryID) {
                        requested[id] = pr
                    }
                    source.requested = requested
                }
                if source.authored != nil || source.requested != nil { next.sources[scope.id] = source }
            }
            next.rebasingRepositories.removeAll { repository in
                let scopes = next.sources.filter { _, source in
                    [source.authored, source.requested].contains { $0?.values.contains { $0.repositoryID == repository } == true }
                }.keys
                return !scopes.isEmpty && scopes.allSatisfy {
                    complete(input.results[$0]?.authored) != nil && complete(input.results[$0]?.requested) != nil
                }
            }
            guard next != old || baseline != next else {
                lastSequence = input.sequence
                return Output()
            }
            guard old.revision < UInt64.max else { return Output(storageFailed: true) }
            next.revision = old.revision + 1
            let events = detect(old: old, next: next, input: input)
            try Task.checkCancellation()
            try store.save(next)
            baseline = next
            lastSequence = input.sequence
            // Cancellation during a write consumes the transition but never delivers stale events.
            return Output(events: Task.isCancelled ? [] : events)
        } catch is CancellationError { return Output() }
        catch { return Output(storageFailed: true) }
    }

    private func load() throws {
        guard !loaded else { return }
        baseline = try store.load()
        loaded = true
    }

    private func reconciled(_ old: PullRequestChangeSnapshot, scopes: [PullRequestChangeScope]) -> PullRequestChangeSnapshot {
        let identities = Set(scopes.map(\.identity))
        guard identities.count <= 1 else { return .init(identity: old.identity) }
        guard identities.first == nil || identities.first == old.identity else {
            return .init(identity: identities.first!)
        }
        var next = old
        let active = Set(scopes.map(\.id))
        let removed = old.sources.filter { !active.contains($0.key) }.values
        let affected = removed.flatMap { [$0.authored, $0.requested].compactMap { $0 }.flatMap { $0.values.map(\.repositoryID) } }
        next.rebasingRepositories = active.isEmpty ? [] : Set(old.rebasingRepositories + affected).sorted()
        next.sources = old.sources.filter { active.contains($0.key) }
        return next
    }

    private func complete(_ result: GitHubPullRequestDiscoveryResult?) -> GitHubPullRequestDiscoveryResult? {
        guard let result, !result.isTruncated, !result.coverageLimitations.contains(.conflictingMetadata) else { return nil }
        return result
    }

    private func repositoryIDs(_ sections: PullRequestChangeInput.Sections) -> Set<String> {
        Set([sections.authored, sections.requested].compactMap { complete($0) }
            .flatMap(\.pullRequests).map { $0.repository.id })
    }

    private func projected(_ result: GitHubPullRequestDiscoveryResult,
                           previous: [String: PullRequestChangeSnapshot.PullRequest]?) -> [String: PullRequestChangeSnapshot.PullRequest] {
        var values: [String: PullRequestChangeSnapshot.PullRequest] = [:]
        for pr in result.pullRequests {
            var value = PullRequestChangeSnapshot.PullRequest(pr)
            if let old = previous?[pr.id] {
                if value.updatedAt < old.updatedAt { values[pr.id] = old; continue }
                // Keep trustworthy details through a gap, with an explicit comparability barrier.
                if !value.reviewsComplete { value.reviewers = old.reviewers }
            }
            values[pr.id] = value
        }
        return values
    }

    private func detect(old: PullRequestChangeSnapshot, next: PullRequestChangeSnapshot,
                        input: PullRequestChangeInput) -> [PullRequestChangeEvent] {
        typealias PR = PullRequestChangeSnapshot.PullRequest
        func observations(_ snapshot: PullRequestChangeSnapshot, requested: Bool) -> [String: [String: PR]] {
            var values: [String: [String: PR]] = [:]
            for (scope, source) in snapshot.sources {
                for (id, pr) in (requested ? source.requested : source.authored) ?? [:] {
                    values[id, default: [:]][scope] = pr
                }
            }
            return values
        }
        func repoSources(_ snapshot: PullRequestChangeSnapshot, repository: String) -> Set<String> {
            Set(snapshot.sources.compactMap { scope, source in
                [source.authored, source.requested].contains { $0?.values.contains { $0.repositoryID == repository } == true }
                    ? scope : nil
            })
        }
        let authoredBefore = observations(old, requested: false)
        let authoredAfter = observations(next, requested: false)
        let requestsBefore = observations(old, requested: true)
        let requestsAfter = observations(next, requested: true)
        let live = input.results.keys.sorted().flatMap { key in
            let section = input.results[key]!
            return [section.authored, section.requested].compactMap { $0 }.flatMap(\.pullRequests)
        }
        var events: [PullRequestChangeEvent] = []
        func append(_ kind: PullRequestChangeEvent.Kind, id: String, state: PR, scopes: Set<String>,
                    signal: PullRequestChangeEvent.Signal, before: String, after: String, reviewer: String? = nil) {
            let pr = live.first { $0.id == id }
            guard let repository = pr?.repository ?? live.first(where: { $0.repository.id == state.repositoryID })?.repository,
                  let url = pr?.browserURL ?? URL(string: repository.url.absoluteString + "/pull/\(state.number)") else { return }
            let actor = reviewer.flatMap { key in
                pr?.latestReviews?.reviews.first { $0.authorLogin.map { changeDigest($0.lowercased()) } == key }?.authorLogin
            }
            let identity = [next.identity, String(next.revision), id, kind.rawValue, reviewer ?? ""].joined(separator: "|")
            events.append(.init(id: changeDigest(identity), kind: kind, pullRequestID: id,
                                repository: repository, number: state.number, title: pr?.title, url: url,
                                observedAt: input.observedAt, actorLogin: actor, signal: signal,
                                previousState: before, currentState: after, sourceIDs: scopes.sorted()))
        }
        for id in Set(requestsBefore.keys).union(requestsAfter.keys).sorted() {
            let before = requestsBefore[id] ?? [:], after = requestsAfter[id] ?? [:]
            guard before.isEmpty != after.isEmpty, let state = after.values.first ?? before.values.first else { continue }
            guard !old.rebasingRepositories.contains(state.repositoryID) else { continue }
            let scopes = repoSources(next, repository: state.repositoryID)
            guard !scopes.isEmpty, scopes == repoSources(old, repository: state.repositoryID),
                  scopes.allSatisfy({ old.sources[$0]?.requested != nil && complete(input.results[$0]?.requested) != nil }) else { continue }
            append(after.isEmpty ? .reviewRequestRemoved : .reviewRequested, id: id, state: state, scopes: scopes,
                   signal: .membership, before: before.isEmpty ? "inactive" : "active", after: after.isEmpty ? "inactive" : "active")
        }
        for id in authoredAfter.keys.sorted() {
            guard let before = authoredBefore[id], let after = authoredAfter[id],
                  !before.isEmpty, Set(before.keys) == Set(after.keys),
                  after.keys.allSatisfy({ complete(input.results[$0]?.authored) != nil }),
                  let previous = before.values.first, let current = after.values.first,
                  !old.rebasingRepositories.contains(current.repositoryID),
                  before.values.allSatisfy({ $0.repositoryID == previous.repositoryID && $0.number == previous.number }),
                  after.values.allSatisfy({ $0.repositoryID == previous.repositoryID && $0.number == previous.number }),
                  after.values.map(\.updatedAt).min()! > before.values.map(\.updatedAt).max()! else { continue }
            let scopes = Set(after.keys)
            if before.values.allSatisfy(\.isDraft), after.values.allSatisfy({ !$0.isDraft }) {
                append(.readyForReview, id: id, state: current, scopes: scopes, signal: .draft, before: "draft", after: "ready")
            }
            var overallKind: PullRequestChangeEvent.Kind?
            if let decision = previous.decision, decision != .unknown,
               before.values.allSatisfy({ $0.decision == decision }),
               after.values.allSatisfy({ $0.decision == current.decision }), current.decision != decision {
                if current.decision == .approved { overallKind = .approved }
                if current.decision == .changesRequested { overallKind = .changesRequested }
            }
            // Unknown -> known alone cannot distinguish metadata enrichment from new review activity.
            if let overallKind {
                append(overallKind, id: id, state: current, scopes: scopes, signal: .decision,
                       before: previous.decision!.rawValue, after: current.decision!.rawValue)
            }
            guard before.values.allSatisfy({ $0.reviewsComplete && $0.reviewers == previous.reviewers }),
                  after.values.allSatisfy({ $0.reviewsComplete && $0.reviewers == current.reviewers }),
                  let oldReviews = previous.reviewers, let newReviews = current.reviewers else { continue }
            for reviewer in newReviews.keys.sorted() {
                let review = newReviews[reviewer]!, prior = oldReviews[reviewer]
                guard prior?.state != review.state, prior?.state != .dismissed,
                      !oldReviews.values.contains(where: { $0.id == review.id }),
                      review.state == .approved || review.state == .changesRequested else { continue }
                let kind: PullRequestChangeEvent.Kind = review.state == .approved ? .approved : .changesRequested
                guard kind != overallKind else { continue }
                append(kind, id: id, state: current, scopes: scopes, signal: .reviewer,
                       before: prior?.state.rawValue ?? "none", after: review.state.rawValue, reviewer: reviewer)
            }
        }
        return events
    }
}
