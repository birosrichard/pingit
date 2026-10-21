import Foundation
import Testing

struct GitHubPullRequestTests {
    @Test func decodesDashboardValues() throws {
        let json = #"""
        {
          "id":"PR_1", "number":42, "title":"Fix menu bar", "url":"https://github.com/octocat/pingit/pull/42",
          "repository":{"id":"R_1", "nameWithOwner":"octocat/pingit", "url":"https://github.com/octocat/pingit"},
          "authorLogin":"octocat", "isDraft":true, "createdAt":"2026-10-20T09:00:00Z", "updatedAt":"2026-10-21T09:00:00Z",
          "reviewStatus":"changesRequested", "checkStatus":"pending",
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
                          reviewStatus: nil, latestReviews: nil, checkStatus: nil, reviewRequests: nil)
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
            reviewStatus: nil, latestReviews: nil, checkStatus: nil, reviewRequests: nil)
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
                reviewStatus: nil, latestReviews: nil, checkStatus: nil, reviewRequests: nil,
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
