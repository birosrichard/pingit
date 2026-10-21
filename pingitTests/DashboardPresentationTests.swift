import Foundation
import Testing

struct DashboardPresentationTests {
    private func pr(review: GitHubReviewStatus? = .unknown, draft: Bool = false, url: URL? = nil,
                    repository: String = "sample-team/project") -> GitHubPullRequest {
        GitHubPullRequest(id: "PR_fixture", number: 12345, title: "Improve native dashboard metadata",
            url: url ?? URL(string: "https://github.com/sample-team/project/pull/12345")!,
            repository: .init(id: "repo", nameWithOwner: repository, url: URL(string: "https://github.com/sample-team/project")!),
            authorLogin: "contributor", isDraft: draft, createdAt: .distantPast,
            updatedAt: Date(timeIntervalSince1970: 1000), reviewStatus: review,
            latestReviews: .init(reviews: [], limitations: []), reviewRequests: nil,
            headRefOid: "head", diffStatistics: GitHubDiffStatistics(changedFiles: 3, additions: 142, deletions: 28))
    }

    @Test(arguments: PullRequestInbox.allCases)
    func everyInboxRetainsIdentityDiffAndCanonicalLink(inbox: PullRequestInbox) {
        let value = pr(draft: inbox == .drafts)
        let display = PullRequestRowPresentation(pr: value, inbox: inbox)
        #expect(display.title == value.title)
        #expect(display.repositoryLabel == "sample-team/project #12345")
        #expect(display.browserURL == value.browserURL)
        #expect(display.avatarOwner == "sample-team")
        #expect(display.diff?.filesLabel == "3 files")
        #expect(display.accessibilityLabel.contains("142 additions, 28 deletions"))
        #expect(display.help.contains("Open on GitHub"))
        #expect(display.compactUpdatedAge(relativeTo: Date(timeIntervalSince1970: 4600)) == "1h")
    }

    @Test func authorAndReviewContextAreMutuallyExclusive() {
        let value = pr(review: .approved)
        let requested = PullRequestRowPresentation(pr: value, inbox: .review)
        #expect(requested.authorLabel == "@contributor" && requested.review == nil)
        #expect(requested.avatarOwner != value.authorLogin)
        for inbox in [PullRequestInbox.authored, .drafts] {
            let display = PullRequestRowPresentation(pr: value, inbox: inbox)
            #expect(display.authorLabel == nil && display.review?.label == "Approved")
            #expect(display.review == value.reviewPresentation)
        }
        #expect(PullRequestRowPresentation(pr: pr(), inbox: .authored).review?.label == "No reviews yet")
    }

    @Test(arguments: [GitHubCheckStatus.success, .failure, .pending, .cancelled, .skipped, .noChecks, .unknown])
    func noCIStateChangesTheDefaultRowOrItsAccessibility(status: GitHubCheckStatus) {
        var value = pr()
        let baseline = PullRequestRowPresentation(pr: value, inbox: .authored)
        value.checks = .init(headOid: "head", status: status, failingCount: status == .failure ? 2 : nil,
                             detailsComplete: status != .unknown, limitation: status == .unknown ? .unavailable : nil)
        #expect(PullRequestRowPresentation(pr: value, inbox: .authored) == baseline)
        #expect(!baseline.accessibilityLabel.contains("Checks") && !baseline.help.contains("Checks"))
        #expect(value.checkStatus == status) // Domain evidence is retained independently of presentation.
    }

    @Test func unavailableDiffAvatarAndUnsafeLinksRemainHonest() {
        var value = pr(url: URL(string: "https://example.com/sample-team/project/pull/12345")!, repository: "invalid owner/project")
        value.diffStatistics = nil
        let display = PullRequestRowPresentation(pr: value, inbox: .authored)
        #expect(display.diff == nil && display.browserURL == nil)
        #expect(display.accessibilityLabel.contains("Diff statistics unavailable"))
        #expect(display.help.contains("GitHub link unavailable"))
        #expect(GitHubAvatar.url(for: display.avatarOwner) == nil)
    }

    @Test func largeDiffAndDraftAccessibilityUseFullNumbers() {
        var value = pr(draft: true)
        value.diffStatistics = GitHubDiffStatistics(changedFiles: 1, additions: 1500000, deletions: 28000)
        let display = PullRequestRowPresentation(pr: value, inbox: .drafts)
        #expect(display.diff?.filesLabel == "1 file" && display.diff?.additionsLabel == "+1.5M")
        #expect(display.accessibilityLabel.contains("Draft pull request"))
        #expect(display.accessibilityLabel.contains("1500000 additions, 28000 deletions"))
    }

    @Test(arguments: PullRequestInbox.allCases)
    func emptyLoadingAndFailureStatesStayDistinct(inbox: PullRequestInbox) {
        let loading = PullRequestEmptyPresentation(inbox: inbox, phase: .loading)
        #expect(loading.isLoading && !loading.isFailure)
        let failure = PullRequestEmptyPresentation(inbox: inbox, phase: .failed)
        #expect(failure.isFailure && !failure.isLoading && failure.message.contains("Refresh"))
        let empty = PullRequestEmptyPresentation(inbox: inbox, phase: .loaded)
        #expect(!empty.isFailure && !empty.isLoading)
        #expect(empty.message.contains("visible to your tokens"))
        #expect(inbox.contextTitle != inbox.shortTitle)
        #expect(inbox.label(in: .init()).hasSuffix("—"))
    }

    @Test func dashboardFitsAvailableScreenAndBoundsTheScrollingRegion() {
        #expect(DashboardLayout.width(availableScreenWidth: 1440) == 460)
        #expect(DashboardLayout.width(availableScreenWidth: 400) == 368)
        #expect(DashboardLayout.width(availableScreenWidth: 280) <= 280)
        #expect(DashboardLayout.listHeight(rowCount: 200, availableScreenHeight: 900) == 420)
        #expect(DashboardLayout.listHeight(rowCount: 200, availableScreenHeight: 500) == 240)
        #expect(DashboardLayout.listHeight(rowCount: 1, availableScreenHeight: 900) == 144)
        #expect(DashboardLayout.listHeight(rowCount: 2, availableScreenHeight: 900, contentHeight: 184) == 184)
        #expect(DashboardLayout.listHeight(rowCount: 200, availableScreenHeight: 900, contentHeight: 18000) == 420)
        #expect(DashboardLayout.listHeight(rowCount: 2, availableScreenHeight: 500, contentHeight: 300) == 240)
    }
}
