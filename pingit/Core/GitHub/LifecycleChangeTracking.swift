import Foundation

extension PullRequestChangeSnapshot {
    struct Lifecycle: Codable, Equatable, Sendable {
        let repositoryID: String
        let number: Int
        var state: GitHubPullRequestState?
        var isDraft: Bool
        var updatedAt: Date
        var verifiedAt: Date
        var terminalObservedAt: Date?
        var sourceIDs: [String]
        var comparable: Bool
    }
}

enum LifecycleChangeTracking {
    static func reconcile(_ snapshot: inout PullRequestChangeSnapshot, scopes: [String]) {
        let active = scopes.sorted()
        guard snapshot.lifecycleScopes != active else { return }
        snapshot.lifecycleScopes = active
        if var values = snapshot.lifecycles {
            for id in values.keys {
                values[id]?.sourceIDs.removeAll { !active.contains($0) }
                values[id]?.comparable = false
            }
            snapshot.lifecycles = values.filter { !$0.value.sourceIDs.isEmpty }
        }
    }

    static func plan(snapshot: PullRequestChangeSnapshot, input: PullRequestChangeInput) -> GitHubLifecyclePlan {
        let values = candidates(snapshot: snapshot, input: input)
        var plan = GitHubLifecyclePlan()
        let allIDs = Set(input.results.values.compactMap { complete($0.authored) }.flatMap(\.pullRequests).map(\.id))
        plan.limited = !allIDs.isSubset(of: Set(values.keys))
        // Oldest verification first. A budget-excluded entry keeps its state but loses
        // comparability, so exceeding the cap never manufactures a later transition.
        for id in values.keys.sorted(by: {
            values[$0]!.verifiedAt == values[$1]!.verifiedAt ? $0 < $1 : values[$0]!.verifiedAt < values[$1]!.verifiedAt
        }) {
            let value = values[id]!
            guard value.state != .merged else { continue }
            guard value.sourceIDs.allSatisfy({ scope in
                guard let result = complete(input.results[scope]?.authored) else { return false }
                return result.pullRequests.filter { $0.id == id }.allSatisfy {
                    $0.repository.id == value.repositoryID && $0.number == value.number
                }
            }),
                  let owner = value.sourceIDs.first else { plan.limited = true; continue }
            if let index = plan.batches.firstIndex(where: { $0.scopeID == owner && $0.ids.count < GitHubLifecyclePlan.batchSize }) {
                plan.batches[index].ids.append(id)
            } else if plan.batches.count < GitHubLifecyclePlan.maximumBatches {
                plan.batches.append(.init(scopeID: owner, ids: [id]))
            } else { plan.limited = true }
        }
        return plan
    }

    static func project(old: PullRequestChangeSnapshot, next: inout PullRequestChangeSnapshot,
                        input: PullRequestChangeInput) -> [PullRequestChangeEvent] {
        var values = candidates(snapshot: old, input: input)
        let plan = plan(snapshot: old, input: input)
        var events: [PullRequestChangeEvent] = []
        for id in values.keys { values[id]?.comparable = false }
        for batch in plan.batches {
            guard let result = input.results[batch.scopeID]?.lifecycles else { continue }
            for id in batch.ids {
                guard var value = values[id], let observation = result.observations[id], observation.id == id,
                      observation.repository.id == value.repositoryID, observation.number == value.number,
                      observation.verifiedAt <= input.observedAt,
                      value.state == nil || observation.verifiedAt >= value.verifiedAt,
                      observation.updatedAt >= value.updatedAt, observation.updatedAt <= input.observedAt,
                      value.sourceIDs.allSatisfy({ scope in
                          input.results[scope]?.authored?.pullRequests.filter { $0.id == id }
                              .allSatisfy { $0.updatedAt <= observation.updatedAt } == true
                      }),
                      let validURL = GitHubNotificationURL.validate(observation.url.absoluteString), validURL.fragment == nil,
                      observation.url.path == "/\(observation.repository.nameWithOwner)/pull/\(value.number)" else { continue }
                let prior = old.lifecycles?[id]
                var kind: PullRequestChangeEvent.Kind?
                var transitionAt: Date?
                if prior?.state == .open && observation.state == .merged {
                    kind = .prMerged; transitionAt = observation.mergedAt
                } else if prior?.state == .open && observation.state == .closed && observation.mergedAt == nil {
                    kind = .prClosed; transitionAt = observation.closedAt
                } else if prior?.state == .closed && observation.state == .open && observation.mergedAt == nil {
                    kind = .prReopened; transitionAt = observation.updatedAt
                }
                if let prior, prior.comparable, prior.sourceIDs == value.sourceIDs,
                   let kind, let transitionAt, transitionAt > prior.verifiedAt,
                   transitionAt <= input.observedAt, observation.updatedAt > prior.updatedAt {
                    let identity = [next.identity, next.epoch.uuidString, id, kind.rawValue,
                                    String(transitionAt.timeIntervalSince1970)].joined(separator: "|")
                    events.append(.init(id: changeDigest(identity), kind: kind, pullRequestID: id,
                        repository: observation.repository, number: value.number, title: nil, url: observation.url,
                        observedAt: input.observedAt, actorLogin: nil, signal: .lifecycle,
                        previousState: prior.state?.rawValue ?? "unknown", currentState: observation.state.rawValue,
                        sourceIDs: value.sourceIDs))
                }
                if observation.state == .open { value.terminalObservedAt = nil }
                else if value.state != observation.state || value.terminalObservedAt == nil {
                    value.terminalObservedAt = input.observedAt
                }
                value.state = observation.state
                value.isDraft = observation.isDraft
                value.updatedAt = observation.updatedAt
                value.verifiedAt = observation.verifiedAt
                value.comparable = true
                values[id] = value
            }
        }
        // nil distinguishes a v1/v2 upgrade from established (possibly empty) v3 tracking.
        // Existing review and comment histories are not edited by lifecycle projection.
        if !values.isEmpty || old.lifecycles != nil || input.results.values.contains(where: { $0.lifecycles != nil }) {
            next.lifecycles = values
        }
        return events
    }

    private static func candidates(snapshot: PullRequestChangeSnapshot, input: PullRequestChangeInput)
        -> [String: PullRequestChangeSnapshot.Lifecycle] {
        var values = (snapshot.lifecycles ?? [:]).filter { _, value in
            let anchor = value.terminalObservedAt ?? value.verifiedAt
            let retention = value.terminalObservedAt == nil ? GitHubLifecyclePlan.unverifiedRetention : GitHubLifecyclePlan.closedRetention
            return input.observedAt < anchor || input.observedAt.timeIntervalSince(anchor) <= retention
        }
        let active = Set(input.scopes.map(\.id))
        for scope in input.scopes.sorted(by: { $0.id < $1.id }) {
            guard let result = complete(input.results[scope.id]?.authored) else { continue }
            var seeds = Dictionary(result.pullRequests.map { ($0.id, PullRequestChangeSnapshot.PullRequest($0)) },
                                   uniquingKeysWith: { first, _ in first })
            // Upgrade can verify already observed PRs even if they disappeared before the
            // first v3 search. Their first direct observation is always a quiet baseline.
            if snapshot.lifecycles == nil {
                for (id, pr) in snapshot.sources[scope.id]?.authored ?? [:] where seeds[id] == nil { seeds[id] = pr }
            }
            for id in seeds.keys.sorted() {
                let pr = seeds[id]!
                if var value = values[id] {
                    guard value.repositoryID == pr.repositoryID, value.number == pr.number else {
                        values[id]?.comparable = false
                        continue
                    }
                    if !value.sourceIDs.contains(scope.id) {
                        value.sourceIDs.append(scope.id); value.sourceIDs.sort(); value.comparable = false
                    }
                    values[id] = value
                } else if values.count < GitHubLifecyclePlan.maximumPullRequests {
                    values[id] = .init(repositoryID: pr.repositoryID, number: pr.number, state: nil,
                        isDraft: pr.isDraft, updatedAt: pr.updatedAt, verifiedAt: input.observedAt,
                        sourceIDs: [scope.id], comparable: false)
                }
            }
        }
        return values.filter { !$0.value.sourceIDs.isEmpty && Set($0.value.sourceIDs).isSubset(of: active) }
    }

    private static func complete(_ result: GitHubPullRequestDiscoveryResult?) -> GitHubPullRequestDiscoveryResult? {
        guard let result, !result.isTruncated, !result.coverageLimitations.contains(.conflictingMetadata) else { return nil }
        return result
    }
}
