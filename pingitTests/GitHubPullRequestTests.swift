import Foundation
import Testing

struct GitHubPullRequestTests {
    @Test func decodesDashboardValues() throws {
        let json = #"""
        {
          "id":"PR_1", "number":42, "title":"Fix menu bar", "url":"https://github.com/octocat/pingit/pull/42",
          "repository":{"id":"R_1", "nameWithOwner":"octocat/pingit", "url":"https://github.com/octocat/pingit"},
          "authorLogin":"octocat", "isDraft":true, "createdAt":"2026-10-20T09:00:00Z", "updatedAt":"2026-10-21T09:00:00Z",
          "headRefOid":"abc", "reviewStatus":"changesRequested", "checks":{"headOid":"abc","status":"pending","detailsComplete":false},
          "reviewRequests":[{"user":{"login":"reviewer"}},{"team":{"organizationLogin":"acme","slug":"macos"}}]
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(GitHubPullRequest.self, from: Data(json.utf8))
        #expect(pr.id == "PR_1")
        #expect(pr.number == 42)
        #expect(pr.title == "Fix menu bar")
        #expect(pr.url.absoluteString == "https://github.com/octocat/pingit/pull/42")
        #expect(pr.repository == GitHubRepository(id: "R_1", nameWithOwner: "octocat/pingit",
                                                 url: URL(string: "https://github.com/octocat/pingit")!))
        #expect(pr.authorLogin == "octocat")
        #expect(pr.isDraft)
        #expect(pr.updatedAt == Date(timeIntervalSince1970: 1_792_573_200))
        #expect(pr.reviewStatus == .changesRequested)
        #expect(pr.checkStatus == .pending)
        #expect(pr.reviewRequests == [.user(login: "reviewer"), .team(organizationLogin: "acme", slug: "macos")])
    }

    @Test func unavailableValuesRemainDistinctFromEmptyRequests() throws {
        let json = #"""
        {"id":"PR_2", "number":1, "title":"New PR", "url":"https://github.com/a/b/pull/1",
         "repository":{"id":"R_2", "nameWithOwner":"a/b", "url":"https://github.com/a/b"},
         "authorLogin":null, "isDraft":false, "createdAt":"2026-10-20T09:00:00Z", "updatedAt":"2026-10-21T09:00:00Z"}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pr = try decoder.decode(GitHubPullRequest.self, from: Data(json.utf8))
        #expect(pr.authorLogin == nil)
        #expect(pr.reviewStatus == nil)
        #expect(pr.latestReviews == nil)
        #expect(pr.checkStatus == nil)
        #expect(pr.reviewRequests == nil)
        let withEmptyRequests = json.dropLast() + #", "reviewRequests":[]}"#
        let loaded = try decoder.decode(GitHubPullRequest.self, from: Data(withEmptyRequests.utf8))
        #expect(loaded.reviewRequests == [])
    }

    @Test(arguments: ["reviewRequired", "approved", "changesRequested", "unknown"])
    func decodesReviewStatus(value: String) throws {
        let status = try JSONDecoder().decode(GitHubReviewStatus.self, from: Data("\"\(value)\"".utf8))
        #expect(status.rawValue == value)
    }

    @Test func reviewerDetailsRoundTrip() throws {
        let details = GitHubLatestReviews(reviews: [
            GitHubPullRequestReview(id: "review", authorLogin: nil, state: .dismissed)
        ], limitations: [.missingIdentity, .reviewerLimit])
        #expect(try JSONDecoder().decode(GitHubLatestReviews.self, from: JSONEncoder().encode(details)) == details)
    }

    @Test(arguments: ["pending", "success", "failure"])
    func decodesCheckStatus(value: String) throws {
        let status = try JSONDecoder().decode(GitHubCheckStatus.self, from: Data("\"\(value)\"".utf8))
        #expect(status.rawValue == value)
    }

    @Test(arguments: [
        "http://github.com/a/b/pull/1", "https://example.com/a/b/pull/1",
        "https://github.com.example.com/a/b/pull/1", "https://user@github.com/a/b/pull/1",
        "https://github.com:443/a/b/pull/1", "javascript:alert(1)",
        "/a/b/pull/1", "https://github.com/a/b/issues/1", "https://github.com/a/b/pull/2",
        "https://github.com/a/b/pull/1?redirect=https://example.com", "https://github.com/a/b/pull/1#fragment",
        "https://github.com/a/b/pull/1/extra", "https://github.com//b/pull/1"
    ])
    func rejectsUnsafeBrowserDestinations(value: String) throws {
        #expect(makePR(url: try #require(URL(string: value))).browserURL == nil)
    }

    @Test func opensCanonicalURLWithoutUsingDisplayMetadata() {
        let url = URL(string: "https://github.com/a/b/pull/1")!
        #expect(makePR(url: url).browserURL == url)
    }

    private func makePR(url: URL) -> GitHubPullRequest {
        GitHubPullRequest(id: "pr", number: 1, title: "Untrusted title https://example.com",
                          url: url, repository: GitHubRepository(id: "repo", nameWithOwner: "other/name",
                                                                 url: URL(string: "https://github.com/other/name")!),
                          authorLogin: nil, isDraft: false, createdAt: .distantPast, updatedAt: .distantPast,
                          reviewStatus: nil, latestReviews: nil, checks: nil, reviewRequests: nil)
    }
}

extension GitHubPullRequestTests {
    @Test(arguments: ["apify", "birosrichard", "some-owner", "Octocat"])
    func publicOwnerAvatarURL(login: String) {
        let url = GitHubAvatar.url(for: login)
        #expect(url?.scheme == "https")
        #expect(url?.host == "github.com")
        #expect(url?.path == "/\(login).png")
        #expect(url?.query == "size=80")
        #expect(url?.user == nil && url?.password == nil)
    }

    @Test(arguments: [nil, "", "Legacy token", "../apify", "apify/repo", "https://example.com", "apify?token=x",
                      "apify#fragment", "apify@example.com", "-apify", "apify-", "ápify", String(repeating: "a", count: 40)] as [String?])
    func invalidOwnerLabelsUsePlaceholder(login: String?) {
        #expect(GitHubAvatar.url(for: login) == nil)
    }

    @Test func repositoryAvatarUsesRepositoryOwnerRatherThanAuthor() {
        let repository = GitHubRepository(id: "repo", nameWithOwner: "apify/apify-web", url: URL(string: "https://github.com/apify/apify-web")!)
        #expect(repository.ownerLogin == "apify")
        #expect(GitHubAvatar.url(for: repository.ownerLogin)?.path == "/apify.png")
        for invalid in ["apify", "apify/", "/repo", "apify/repo/extra"] {
            let value = GitHubRepository(id: "repo", nameWithOwner: invalid, url: repository.url)
            #expect(GitHubAvatar.url(for: value.ownerLogin) == nil)
        }
    }
}

extension GitHubPullRequestTests {
    @Test(arguments: [(-60.0, "now"), (0, "now"), (59, "now"), (60, "1m"), (3599, "59m"),
                      (3600, "1h"), (86399, "23h"), (86400, "1d"), (259200, "3d")])
    func compactUpdatedAge(seconds: Double, expected: String) {
        let pr = GitHubPullRequest(id: "age", number: 1, title: "Title", url: URL(string: "https://github.com/a/b/pull/1")!,
            repository: GitHubRepository(id: "r", nameWithOwner: "a/b", url: URL(string: "https://github.com/a/b")!),
            authorLogin: nil, isDraft: false, createdAt: .distantPast, updatedAt: Date(timeIntervalSince1970: 0),
            reviewStatus: nil, latestReviews: nil, checks: nil, reviewRequests: nil)
        #expect(pr.compactUpdatedAge(relativeTo: Date(timeIntervalSince1970: seconds)) == expected)
    }
}

struct PullRequestReviewPresentationTests {
    private func review(_ state: GitHubPullRequestReview.State, _ login: String? = "reviewer") -> GitHubPullRequestReview {
        .init(id: login ?? "deleted", authorLogin: login, state: state)
    }
    private func display(_ values: [GitHubPullRequestReview], limitations: Set<GitHubLatestReviews.Limitation> = [],
                         status: GitHubReviewStatus? = .unknown) -> PullRequestReviewPresentation {
        .init(status: status, reviews: .init(reviews: values, limitations: limitations))
    }

    @Test func completeEmptyAndUnavailableDiffer() {
        #expect(display([]).label == "No reviews yet")
        #expect(display([], limitations: [.reviewerLimit]).label == "No review decision")
        #expect(display([], limitations: [.unavailable]).label == "No review decision")
        #expect(PullRequestReviewPresentation(status: nil, reviews: nil).label == "No review decision")
    }

    @Test func individualApprovalsAreActivityRatherThanOverallApproval() {
        let bot = display([review(.approved, "macroscopeapp[bot]")])
        #expect(bot.label == "1 approval")
        #expect(bot.tone == .neutral)
        #expect(bot.detail.contains("No authoritative overall review decision"))
        #expect(bot.detail.contains("does not establish merge readiness"))
        #expect(display([review(.approved, "alice"), review(.approved, "bob")]).label == "2 approvals")
        #expect(display([review(.approved, "Alice"), review(.approved, "alice")]).label == "1 approval")
    }

    @Test func mixedStatesPrioritizeChangesAndExposeActivityDetails() {
        let result = display([review(.approved, "alice"), review(.changesRequested, "bob")])
        #expect(result.label == "Changes requested by reviewer")
        #expect(result.detail.contains("1 approved"))
        #expect(result.detail.contains("1 changes requested"))
        #expect(display([review(.changesRequested)]).label == "Changes requested by reviewer")
        #expect(display([review(.commented)]).label == "Review comments")
    }

    @Test(arguments: [GitHubPullRequestReview.State.dismissed, .pending, .unknown])
    func nonApprovalsAreNeverCounted(state: GitHubPullRequestReview.State) {
        #expect(display([review(state)]).label == "No review decision")
        #expect(display([review(state)]).tone == .neutral)
    }

    @Test func incompleteDetailsQualifyVisibleApprovalCounts() {
        #expect(display([review(.approved)], limitations: [.reviewerLimit]).label == "At least 1 approval")
        let missing = display([review(.approved, nil)], limitations: [.missingIdentity])
        #expect(missing.label == "No review decision")
        #expect(missing.detail.contains("incomplete"))
    }

    @Test(arguments: [GitHubReviewStatus.approved, .changesRequested, .reviewRequired])
    func authoritativeDecisionsAlwaysWin(status: GitHubReviewStatus) {
        let result = display([review(.commented)], limitations: [.reviewerLimit], status: status)
        let expected: String = switch status {
        case .approved: "Approved"
        case .changesRequested: "Changes requested"
        case .reviewRequired: "Review required"
        case .unknown: "unused"
        }
        #expect(result.label == expected)
        #expect(result.detail.contains("overall review decision"))
    }
}

struct PullRequestDiffStatisticsTests {
    @Test func zeroAndSingularAndLargeCounts() throws {
        let zero = try #require(GitHubDiffStatistics(changedFiles: 0, additions: 0, deletions: 0))
        #expect(zero.filesLabel == "0 files" && zero.additionsLabel == "+0" && zero.deletionsLabel == "−0")
        let one = try #require(GitHubDiffStatistics(changedFiles: 1, additions: 142, deletions: 28))
        #expect(one.filesLabel == "1 file")
        #expect(one.accessibilityLabel == "1 file changed, 142 additions, 28 deletions")
        let large = try #require(GitHubDiffStatistics(changedFiles: 1200, additions: 1500000, deletions: 28000))
        #expect(large.filesLabel == "1.2K files")
        #expect(large.additionsLabel == "+1.5M" && large.deletionsLabel == "−28K")
        #expect(large.accessibilityLabel.contains("1500000 additions"))
    }

    @Test func unavailableAndInvalidCounts() {
        #expect(GitHubDiffStatistics(changedFiles: nil, additions: 0, deletions: 0) == nil)
        #expect(GitHubDiffStatistics(changedFiles: 0, additions: nil, deletions: 0) == nil)
        #expect(GitHubDiffStatistics(changedFiles: 0, additions: 0, deletions: nil) == nil)
        #expect(GitHubDiffStatistics(changedFiles: -1, additions: 0, deletions: 0) == nil)
    }
}

extension PullRequestDiffStatisticsTests {
    @Test func duplicateDiffMetadataUsesOnlyLatestSnapshotAndRejectsConflicts() {
        func pr(head: String, updated: TimeInterval = 1, additions: Int?) -> GitHubPullRequest {
            GitHubPullRequest(id: "pr", number: 1, title: "Title", url: URL(string: "https://github.com/a/b/pull/1")!,
                repository: .init(id: "r", nameWithOwner: "a/b", url: URL(string: "https://github.com/a/b")!),
                authorLogin: nil, isDraft: false, createdAt: .distantPast, updatedAt: Date(timeIntervalSince1970: updated),
                reviewStatus: nil, latestReviews: nil, checks: nil, reviewRequests: nil,
                headRefOid: head, diffStatistics: GitHubDiffStatistics(changedFiles: 1, additions: additions, deletions: 0))
        }
        func merge(_ values: [GitHubPullRequest]) -> GitHubPullRequestDiscoveryResult {
            .merged(values.map { .init(pullRequests: [$0], truncationReasons: [], coverageLimitations: []) })
        }
        let complete = pr(head: "a", additions: 12)
        let missing = pr(head: "a", additions: nil)
        #expect(merge([complete, missing]).pullRequests.first?.diffStatistics?.additions == 12)
        #expect(merge([missing, complete]).pullRequests.first?.diffStatistics?.additions == 12)
        let newer = pr(head: "b", updated: 2, additions: nil)
        for values in [[complete, newer], [newer, complete]] {
            #expect(merge(values).pullRequests.first?.headRefOid == "b")
            #expect(merge(values).pullRequests.first?.diffStatistics == nil)
        }
        #expect(merge([complete, pr(head: "b", additions: 12)]).pullRequests.first?.headRefOid == nil)
        let conflict = merge([complete, pr(head: "a", additions: 13), complete])
        #expect(conflict.pullRequests.first?.diffStatistics == nil)
        #expect(conflict.coverageLimitations.contains(.conflictingMetadata))
    }
}

struct PullRequestChecksTests {
    typealias Counts = GitHubPullRequestSearchResponse.CheckCounts

    private func rollup(_ state: String?, runs: [String: Int] = [:], statuses: [String: Int] = [:],
                        total: Int? = nil, complete: Bool = true) -> GitHubCheckSnapshot {
        GitHubPullRequestSearchResponse.CheckRollup(state: state, contexts: Counts(
            totalCount: total ?? (runs.values.reduce(0, +) + statuses.values.reduce(0, +)),
            checkRunCount: runs.values.reduce(0, +), statusContextCount: statuses.values.reduce(0, +),
            checkRunCountsByState: complete ? runs.map { .init(state: $0.key, count: $0.value) } : nil,
            statusContextCountsByState: statuses.map { .init(state: $0.key, count: $0.value) }
        )).domain(headOid: "head")
    }

    @Test func checksAndLegacyStatusesShareOneRollup() {
        #expect(rollup("SUCCESS", runs: ["SUCCESS": 12], statuses: ["SUCCESS": 2]).status == .success)
        #expect(rollup("SUCCESS", statuses: ["SUCCESS": 1]).status == .success)
        #expect(rollup("FAILURE", statuses: ["ERROR": 1, "SUCCESS": 1]).failingCount == 1)
        #expect(rollup("PENDING", statuses: ["PENDING": 2]).status == .pending)
    }

    @Test(arguments: ["FAILURE", "TIMED_OUT", "STARTUP_FAILURE", "ACTION_REQUIRED"])
    func failuresAreNeverHidden(state: String) {
        let result = rollup("FAILURE", runs: [state: 2, "SUCCESS": 3, "IN_PROGRESS": 1])
        #expect(result.status == .failure && result.failingCount == 2 && result.detailsComplete)
        let contradiction = rollup("SUCCESS", runs: [state: 1, "SUCCESS": 20])
        #expect(contradiction.status == .failure && contradiction.failingCount == nil)
        #expect(!contradiction.detailsComplete)
    }

    @Test(arguments: ["PENDING", "QUEUED", "IN_PROGRESS", "WAITING"])
    func pendingCannotPass(state: String) {
        #expect(rollup("PENDING", runs: [state: 1]).status == .pending)
        #expect(rollup("PENDING", runs: [state: 1, "SUCCESS": 5]).status == .pending)
        #expect(rollup("SUCCESS", runs: [state: 1, "SUCCESS": 5]).status == .pending)
        #expect(rollup("FAILURE", runs: [state: 1, "FAILURE": 1]).status == .failure)
    }

    @Test func cancellationAndNeutralConclusionsNeverSupplySuccess() {
        #expect(rollup("FAILURE", runs: ["CANCELLED": 1]).status == .cancelled)
        #expect(rollup("SUCCESS", runs: ["CANCELLED": 1, "SUCCESS": 1]).status == .cancelled)
        #expect(rollup("PENDING", runs: ["CANCELLED": 1, "IN_PROGRESS": 1]).status == .pending)
        for state in ["SKIPPED", "NEUTRAL"] {
            #expect(rollup("SUCCESS", runs: [state: 1]).status == .skipped)
            #expect(rollup("SUCCESS", runs: [state: 1, "SUCCESS": 1]).status == .skipped)
        }
        #expect(rollup("FAILURE", runs: ["FAILURE": 1, "CANCELLED": 1]).status == .failure)
    }

    @Test func emptyAndUnavailableAreDistinct() {
        #expect(rollup("PENDING").status == .noChecks)
        #expect(rollup("SUCCESS").status == .noChecks)
        let unavailable = GitHubPullRequestSearchResponse.CheckRollup(state: nil, contexts: nil).domain(headOid: "head")
        #expect(unavailable.status == .unknown && unavailable.failingCount == nil)
        #expect(GitHubCheckSnapshot.unavailable(headOid: "head").status == .unknown)
    }

    @Test func incompleteCountsAndFutureStatesCannotPass() {
        for result in [rollup("SUCCESS", runs: ["SUCCESS": 1], total: 2),
                       rollup("SUCCESS", runs: ["SUCCESS": 1], complete: false),
                       rollup("FUTURE", runs: ["SUCCESS": 1]),
                       rollup("SUCCESS", runs: ["FUTURE": 1]),
                       rollup("SUCCESS", runs: ["STALE": 1]),
                       rollup("SUCCESS", runs: ["COMPLETED": 1])] {
            #expect(result.status == .unknown && !result.detailsComplete && result.failingCount == nil)
        }
        #expect(rollup("FAILURE", runs: ["FAILURE": 2], total: 3).failingCount == nil)
        #expect(rollup("FAILURE", complete: false).status == .failure)
        #expect(rollup("PENDING", complete: false).status == .pending)
    }

    @Test func malformedCountersNeverSupplySuccessOrInventExactCounts() {
        for entries in [[Counts.StateCount(state: "SUCCESS", count: -1)],
                        [.init(state: "SUCCESS", count: 1), .init(state: "SUCCESS", count: 1)],
                        [.init(state: "SUCCESS", count: Int.max)]] {
            let counts = Counts(totalCount: 2, checkRunCount: 2, statusContextCount: 0,
                                checkRunCountsByState: entries, statusContextCountsByState: [])
            let snapshot = GitHubPullRequestSearchResponse.CheckRollup(state: "SUCCESS", contexts: counts).domain(headOid: "head")
            #expect(snapshot.status == .unknown && !snapshot.detailsComplete && snapshot.failingCount == nil)
        }
    }
}

struct PullRequestCheckMergeTests {
    private func pr(_ status: GitHubCheckStatus, head: String = "a", updated: TimeInterval = 1,
                    count: Int? = nil, limitation: GitHubCheckSnapshot.Limitation? = nil) -> GitHubPullRequest {
        GitHubPullRequest(id: "pr", number: 1, title: "Title", url: URL(string: "https://github.com/a/b/pull/1")!,
            repository: .init(id: "r", nameWithOwner: "a/b", url: URL(string: "https://github.com/a/b")!),
            authorLogin: nil, isDraft: false, createdAt: .distantPast, updatedAt: Date(timeIntervalSince1970: updated),
            reviewStatus: .reviewRequired, latestReviews: nil,
            checks: .init(headOid: head, status: status, failingCount: count, detailsComplete: limitation == nil, limitation: limitation),
            reviewRequests: nil, headRefOid: head)
    }

    private func merge(_ values: [GitHubPullRequest]) -> GitHubPullRequestDiscoveryResult {
        .merged(values.map { .init(pullRequests: [$0], truncationReasons: [], coverageLimitations: []) })
    }

    @Test func inaccessibleTokenCanYieldToValidatedVisibleChecksForTheSameHead() {
        let unknown = pr(.unknown, limitation: .unavailable)
        let visible = pr(.success)
        for inputs in [[unknown, visible], [visible, unknown]] {
            let result = merge(inputs)
            #expect(result.pullRequests.first?.checkStatus == .success)
            #expect(result.pullRequests.first?.reviewStatus == .reviewRequired)
            #expect(!result.coverageLimitations.contains(.conflictingMetadata))
        }
    }

    @Test(arguments: [GitHubCheckStatus.pending, .failure, .noChecks, .cancelled, .skipped, .unknown])
    func conflictingResultsNeverSelectPassingByOrder(other: GitHubCheckStatus) {
        let success = pr(.success)
        let competing = pr(other, limitation: other == .unknown ? .incomplete : nil)
        for inputs in [[success, competing], [competing, success], [success, competing, success],
                       [success, success, competing], [competing, success, success]] {
            let result = merge(inputs)
            let expected: GitHubCheckStatus = other == .failure ? .failure : other == .pending ? .pending : .unknown
            #expect(result.pullRequests.first?.checkStatus == expected)
            #expect(result.pullRequests.first?.checks?.failingCount == nil)
            #expect(result.coverageLimitations.contains(.conflictingMetadata))
        }
    }

    @Test func matchingFailuresKeepCountsButDisagreementsHidePrecision() {
        let failure = pr(.failure, count: 2)
        #expect(merge([failure, failure]).pullRequests.first?.checks?.failingCount == 2)
        for inputs in [[failure, pr(.failure, count: 3)], [failure, pr(.pending)], [pr(.pending), failure]] {
            #expect(merge(inputs).pullRequests.first?.checkStatus == .failure)
            #expect(merge(inputs).pullRequests.first?.checks?.failingCount == nil)
        }
    }

    @Test func differingHeadsAtTheSameTimestampRemainUnknownEvenWithAThirdVote() {
        let first = pr(.success)
        let second = pr(.failure, head: "b", count: 1)
        for inputs in [[first, second, first], [second, first, first], [first, first, second]] {
            let result = merge(inputs)
            #expect(result.pullRequests.first?.headRefOid == nil)
            #expect(result.pullRequests.first?.checkStatus == .unknown)
            #expect(result.pullRequests.first?.checks?.limitation == .conflicting)
            #expect(result.coverageLimitations.contains(.conflictingMetadata))
        }
    }

    @Test func olderHeadCannotFillMissingChecksOnTheNewHead() {
        let old = pr(.success)
        let new = pr(.unknown, head: "b", updated: 2, limitation: .unavailable)
        for inputs in [[old, new], [new, old]] {
            let result = merge(inputs).pullRequests.first
            #expect(result?.headRefOid == "b" && result?.checks?.headOid == "b")
            #expect(result?.checkStatus == .unknown)
        }
        #expect(merge([pr(.failure, count: 2), pr(.success, head: "b", updated: 2)]).pullRequests.first?.checkStatus == .success)
    }

    @Test func invalidSnapshotHeadIsRejectedAtTheDomainBoundary() {
        var value = pr(.success)
        value.headRefOid = "b"
        #expect(value.checkStatus == .unknown)
        #expect(value.currentChecks?.limitation == .headMismatch)
    }
}
