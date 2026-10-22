import Foundation

// Pure projection used inside the existing detector's compare -> commit transaction.
enum ConversationChangeTracking {
    static func plan(source: PullRequestChangeSnapshot.Source?, sections: PullRequestChangeInput.Sections,
                     at: Date) -> GitHubConversationPlan {
        // Stale, conflicting and truncated search results cannot prove current eligibility.
        guard complete(sections.authored), complete(sections.requested) else { return .init(limited: true) }
        let authored = Set(sections.authored?.pullRequests.map(\.id) ?? [])
        let requested = Set(sections.requested?.pullRequests.map(\.id) ?? [])
        let old = source?.conversations ?? [:]
        let retained = old.filter { _, value in
            value.lastRequestedAt.map { at >= $0 && at.timeIntervalSince($0) <= GitHubConversationPlan.retention } ?? false
        }.keys
        let ids = authored.union(requested).union(retained)
        let targets = ids.sorted {
            if authored.contains($0) != authored.contains($1) { return authored.contains($0) }
            if requested.contains($0) != requested.contains($1) { return requested.contains($0) }
            return $0 < $1
        }.prefix(GitHubConversationPlan.maximumPullRequests).map { id in
            GitHubConversationPlan.Target(id: id, authored: authored.contains(id),
                lastRequestedAt: requested.contains(id) ? at : old[id]?.lastRequestedAt,
                fingerprint: old[id]?.comparable == true ? old[id]?.fingerprint : nil)
        }
        return .init(targets: targets, limited: ids.count > GitHubConversationPlan.maximumPullRequests)
    }

    static func reconcile(_ snapshot: inout PullRequestChangeSnapshot, scopes: [String]) {
        let scopes = scopes.sorted()
        guard snapshot.conversationScopes != scopes else { return }
        // Changing any credential topology conservatively rebases comment coverage, including
        // scopes that have not yet produced a PR result. Ordinary review history stays intact.
        snapshot.conversationScopes = scopes
        for source in snapshot.sources.keys {
            guard var values = snapshot.sources[source]?.conversations else { continue }
            for id in values.keys { values[id]?.comparable = false }
            snapshot.sources[source]?.conversations = values
        }
    }

    static func project(old: PullRequestChangeSnapshot, next: inout PullRequestChangeSnapshot,
                        input: PullRequestChangeInput) -> [PullRequestChangeEvent] {
        var events: [PullRequestChangeEvent] = []
        // Incomplete/missing results retain IDs and timestamps, but break comparability.
        // The next complete observation is quiet rather than replaying activity across a gap.
        for scope in input.scopes {
            var source = next.sources[scope.id] ?? .init()
            let previous = old.sources[scope.id]?.conversations ?? [:]
            var values = previous
            let sections = input.results[scope.id]
            let result = sections?.conversations
            for id in values.keys { values[id]?.comparable = false }
            if let sections, complete(sections.authored), complete(sections.requested), let result {
                // Prune only when fresh complete eligibility searches prove the retention expired.
                let eligible = Set(plan(source: old.sources[scope.id], sections: sections, at: input.observedAt).targets.map(\.id))
                values = values.filter { eligible.contains($0.key) }
                for id in result.retiredIDs { values.removeValue(forKey: id) }
                for (id, observation) in result.observations where eligible.contains(id) {
                    let prior = previous[id]
                    guard observation.verifiedAt <= input.observedAt,
                          prior.map({ observation.verifiedAt >= $0.verifiedAt }) ?? true else { continue }
                    if observation.comments == nil {
                        guard var value = prior, value.comparable,
                              value.fingerprint == observation.fingerprint else { continue }
                        value.verifiedAt = observation.verifiedAt
                        value.lastRequestedAt = observation.lastRequestedAt
                        values[id] = value
                        continue
                    }
                    let comments = observation.comments ?? []
                    let ids = Set(prior?.commentIDs ?? []).union(comments.map(\.id))
                    guard ids.count <= 3000 else { continue }
                    values[id] = .init(repositoryID: observation.repository.id, number: observation.number,
                        fingerprint: observation.fingerprint, verifiedAt: observation.verifiedAt,
                        commentIDs: ids.sorted(), comparable: true, lastRequestedAt: observation.lastRequestedAt)
                }
            }
            source.conversations = values.isEmpty && source.conversations == nil ? nil : values
            if source.authored != nil || source.requested != nil || source.conversations != nil { next.sources[scope.id] = source }
        }
        let ids = Set(input.results.values.flatMap { $0.conversations?.observations.keys.map { $0 } ?? [] })
        for id in ids.sorted() {
            let contributors = input.scopes.filter { scope in
                old.sources[scope.id]?.conversations?[id] != nil
                    || next.sources[scope.id]?.conversations?[id] != nil
            }.map(\.id).sorted()
            guard !contributors.isEmpty else { continue }
            let before = contributors.compactMap { old.sources[$0]?.conversations?[id] }
            let after = contributors.compactMap { next.sources[$0]?.conversations?[id] }
            guard before.count == contributors.count, after.count == contributors.count,
                  before.allSatisfy(\.comparable), after.allSatisfy(\.comparable),
                  Set(before.map(\.repositoryID)).count == 1, Set(after.map(\.repositoryID)) == Set(before.map(\.repositoryID)),
                  Set(before.map(\.number)).count == 1, Set(after.map(\.number)) == Set(before.map(\.number)),
                  Set(after.map(\.fingerprint)).count == 1,
                  contributors.allSatisfy({ input.results[$0]?.conversations?.observations[id] != nil }) else { continue }
            let observations = contributors.compactMap { input.results[$0]?.conversations?.observations[id] }
            let seen = Set(before.flatMap(\.commentIDs))
            let floor = before.map(\.verifiedAt).max() ?? input.observedAt
            let current = observations.flatMap { $0.comments ?? [] }
            let byID = Dictionary(grouping: current, by: \.id)
            for commentID in byID.keys.sorted() where !seen.contains(commentID) {
                guard let candidates = byID[commentID], let comment = candidates.first,
                      candidates.count == contributors.count, candidates.allSatisfy({ $0 == comment }),
                      comment.relevant, comment.publishedAt > floor,
                      comment.publishedAt <= input.observedAt,
                      let observation = observations.first else { continue }
                let eventID = changeDigest([next.identity, next.epoch.uuidString, id, commentID, comment.kind.rawValue].joined(separator: "|"))
                events.append(.init(id: eventID, kind: comment.kind, pullRequestID: id,
                    repository: observation.repository, number: observation.number, title: nil, url: comment.url,
                    observedAt: input.observedAt, actorLogin: comment.actorLogin, signal: .conversation,
                    previousState: "unseen", currentState: "published", sourceIDs: contributors,
                    actorIsBot: comment.isBot, relatedReviewIDs: comment.reviewID.map { [$0] } ?? [], threadID: comment.threadID))
            }
        }
        return events
    }

    private static func complete(_ result: GitHubPullRequestDiscoveryResult?) -> Bool {
        guard let result else { return false }
        return !result.isTruncated && !result.coverageLimitations.contains(.conflictingMetadata)
    }
}
