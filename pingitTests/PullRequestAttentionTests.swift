import Foundation
import Testing

struct PullRequestAttentionTests {
    private func pr(_ id: String = "pr", author: String? = "viewer", draft: Bool = false,
                    status: GitHubReviewStatus? = .reviewRequired,
                    requests: [GitHubReviewRequest]? = nil,
                    reviews: GitHubLatestReviews? = nil,
                    updated: Date = .distantPast) -> GitHubPullRequest {
        GitHubPullRequest(id: id, number: 1, title: "Fixture", url: URL(string: "https://github.com/a/b/pull/1")!,
            repository: .init(id: "repo", nameWithOwner: "a/b", url: URL(string: "https://github.com/a/b")!),
            authorLogin: author, isDraft: draft, createdAt: .distantPast, updatedAt: updated,
            reviewStatus: status, latestReviews: reviews, reviewRequests: requests)
    }

    private func result(_ prs: [GitHubPullRequest], truncated: Bool = false) -> GitHubPullRequestDiscoveryResult {
        .init(pullRequests: prs, truncationReasons: truncated ? [.pageLimit] : [],
              coverageLimitations: [.tokenVisibility, .directReviewRequestsOnly])
    }

    private func classify(_ value: GitHubPullRequest) -> PullRequestAttention {
        .classify(value, viewerLogin: "VIEWER", coverage: .current)
    }

    @Test func directUserRequestIsAuthoritativeEvenWithoutReviewDecision() {
        #expect(classify(pr(author: "other", status: nil, requests: [.user(login: "viewer")])) == .needsAttention(.reviewRequested))
        #expect(classify(pr(author: "other", requests: [.user(login: "someone-else")])) == .waitingOnOthers)
        #expect(classify(pr(author: "other", requests: [.team(organizationLogin: "org", slug: "viewer")])) == .waitingOnOthers)
    }

    @Test func authoredChangesRequestedUsesOverallDecision() {
        let approvals = GitHubLatestReviews(reviews: [.init(id: "r", authorLogin: "reviewer", state: .approved)], limitations: [])
        #expect(classify(pr(status: .changesRequested, reviews: approvals)) == .needsAttention(.changesRequested))
    }

    @Test(arguments: [GitHubReviewStatus.reviewRequired, .approved])
    func authoredWaitingIsNeitherActionNorMergeReadiness(status: GitHubReviewStatus) {
        let value = classify(pr(status: status))
        #expect(value == .waitingOnOthers && value.reason == nil)
        #expect(value.explanation.contains("does not establish merge readiness"))
    }

    @Test(arguments: [GitHubReviewStatus.reviewRequired, .approved, .changesRequested, .unknown])
    func draftPrecedesEveryReviewSignal(status: GitHubReviewStatus) {
        #expect(classify(pr(draft: true, status: status, requests: [.user(login: "viewer")])) == .workInProgress)
        #expect(classify(pr(author: "other", draft: true, status: status, requests: [.user(login: "viewer")])).reason == nil)
    }

    @Test func missingAndUnknownDecisionNeverUseIndividualReviewsToInferAction() {
        let changes = GitHubLatestReviews(reviews: [.init(id: "r", authorLogin: "reviewer", state: .changesRequested)], limitations: [])
        for status: GitHubReviewStatus? in [nil, .unknown] {
            #expect(classify(pr(status: status, reviews: changes)) == .unknown(.missingMetadata))
        }
        #expect(classify(pr(author: "other", requests: nil)) == .unknown(.missingMetadata))
        #expect(classify(pr(author: nil)) == .unknown(.missingMetadata))
        #expect(PullRequestAttention.classify(pr(), viewerLogin: nil, coverage: .current) == .unknown(.missingMetadata))
    }

    @Test func ageAndReviewerCommentsNeverCreateAction() {
        let comments = GitHubLatestReviews(reviews: [.init(id: "r", authorLogin: "reviewer", state: .commented)], limitations: [])
        #expect(classify(pr(reviews: comments, updated: .distantPast)) == .waitingOnOthers)
        #expect(classify(pr(reviews: comments, updated: .distantFuture)) == .waitingOnOthers)
    }

    @Test(arguments: [PullRequestAttention.Coverage.previous, .incomplete, .conflicting])
    func coverageGatesEveryClaim(coverage: PullRequestAttention.Coverage) {
        for value in [pr(status: .changesRequested), pr(author: "other", requests: [.user(login: "viewer")]), pr(draft: true)] {
            let attention = PullRequestAttention.classify(value, viewerLogin: "viewer", coverage: coverage)
            #expect(attention.reason == nil)
            if case .unknown = attention {} else { Issue.record("Incomplete evidence must remain unknown") }
        }
    }

    @Test func duplicateRequestsDoNotDuplicateRowsOrCounts() throws {
        let value = pr(author: "other", requests: [.user(login: "viewer")])
        let merged = GitHubPullRequestDiscoveryResult.merged([result([value]), result([value]), result([value])])
        let state = PullRequestSectionState(phase: .loaded, result: merged)
        #expect(PullRequestInbox.review.countText(in: state) == "1")
        #expect(PullRequestInbox.review.prioritizedPullRequests(in: state, viewerLogin: "viewer").count == 1)
        #expect(state.attention(for: try #require(merged.pullRequests.first), viewerLogin: "viewer") == .needsAttention(.reviewRequested))
    }

    @Test func conflictingDecisionsRequestsAndReviewerStatesRemainNeutralAcrossTokenOrders() throws {
        let reviewA = GitHubLatestReviews(reviews: [.init(id: "r", authorLogin: "reviewer", state: .approved)], limitations: [])
        let reviewB = GitHubLatestReviews(reviews: [.init(id: "r", authorLogin: "reviewer", state: .changesRequested)], limitations: [])
        let pairs = [
            [pr(status: .changesRequested), pr(status: .approved)],
            [pr(author: "other", requests: [.user(login: "viewer")]), pr(author: "other", requests: [])],
            [pr(status: .changesRequested, reviews: reviewA), pr(status: .changesRequested, reviews: reviewB)]
        ]
        for pair in pairs {
            for values in [pair, Array(pair.reversed()), pair + [pair[0]]] {
                let merged = GitHubPullRequestDiscoveryResult.merged(values.map { result([$0]) })
                let state = PullRequestSectionState(phase: .loaded, result: merged)
                #expect(state.attention(for: try #require(merged.pullRequests.first), viewerLogin: "viewer") == .unknown(.conflicting))
            }
        }
    }

    @Test func partialResponseRetainsMissingRowsWithProvenanceUntilCompleteReconciliation() {
        let old = pr("old", status: .changesRequested)
        let new = pr("new", status: .approved)
        let previous = PullRequestSectionState.loaded(result([old]), previous: nil, at: .distantPast)
        let partial = PullRequestSectionState.loaded(result([new], truncated: true), previous: previous, at: .now)
        #expect(Set(partial.result?.pullRequests.map(\.id) ?? []) == ["old", "new"])
        #expect(partial.previousPullRequestIDs == ["old"])
        #expect(partial.attention(for: old, viewerLogin: "viewer") == .unknown(.previous))
        #expect(partial.attention(for: new, viewerLogin: "viewer") == .unknown(.incomplete))
        #expect(PullRequestInbox.authored.countText(in: partial) == "2")
        let complete = PullRequestSectionState.loaded(result([new]), previous: partial, at: .now)
        #expect(complete.result?.pullRequests == [new])
        #expect(complete.previousPullRequestIDs.isEmpty)
        #expect(complete.attention(for: new, viewerLogin: "viewer") == .waitingOnOthers)
    }

    @Test func stablePartitionKeepsTiesAndOriginalTabs() {
        let values = [pr("waiting-1"), pr("action-1", status: .changesRequested), pr("waiting-2", status: .approved),
                      pr("action-2", status: .changesRequested), pr("draft", draft: true)]
        let state = PullRequestSectionState(phase: .loaded, result: result(values))
        #expect(PullRequestInbox.authored.prioritizedPullRequests(in: state, viewerLogin: "viewer").map(\.id)
                == ["action-1", "action-2", "waiting-1", "waiting-2"])
        #expect(PullRequestInbox.drafts.prioritizedPullRequests(in: state, viewerLogin: "viewer").map(\.id) == ["draft"])
        var previous = state
        previous.phase = .failed
        #expect(PullRequestInbox.authored.prioritizedPullRequests(in: previous, viewerLogin: "viewer").map(\.id)
                == ["waiting-1", "action-1", "waiting-2", "action-2"])
    }

    @Test func classificationChangesWithoutChangingMembershipCountsOrLinks() {
        let waiting = pr()
        let action = pr(status: .changesRequested)
        let approved = pr(status: .approved)
        #expect(classify(waiting) == .waitingOnOthers)
        #expect(classify(action) == .needsAttention(.changesRequested))
        #expect(classify(approved) == .waitingOnOthers)
        for value in [waiting, action, approved] {
            let state = PullRequestSectionState(phase: .loaded, result: result([value]))
            #expect(PullRequestInbox.authored.countText(in: state) == "1")
            let display = PullRequestRowPresentation(pr: value, inbox: .authored, attention: classify(value))
            #expect(display.browserURL == value.browserURL && display.review == value.reviewPresentation)
        }
    }

    @Test(arguments: PullRequestAttentionReason.allCases)
    func typedReasonsAndRowAccessibilityExplainTheAction(reason: PullRequestAttentionReason) {
        #expect(reason.id == reason.rawValue && !reason.systemImage.isEmpty)
        #expect(reason.emphasis == .accent)
        let attention = PullRequestAttention.needsAttention(reason)
        let display = PullRequestRowPresentation(pr: pr(), inbox: .authored, attention: attention)
        #expect(display.accessibilityLabel.contains(reason.label))
        #expect(display.help.contains(reason.explanation))
        #expect(attention.accessibilityLabel.contains("Needs attention"))
    }

    @Test func incompleteEmptyInboxNeverClaimsCaughtUp() {
        let display = PullRequestEmptyPresentation(inbox: .review, phase: .loaded, isIncomplete: true)
        #expect(display.title == "Results are incomplete")
        #expect(display.message.contains("may be missing"))
        #expect(!display.isLoading && !display.isFailure)
    }

    @Test func menuBarSignalRemainsConnectionOnlyAndTabsCountDisplayedRows() {
        #expect(MenuBarIndicatorPresentation(isConnected: true).accessibilityLabel == "pingit — Connected")
        #expect(MenuBarIndicatorPresentation(isConnected: false).accessibilityLabel == "pingit — Not connected")
        #expect(MenuBarIndicatorPresentation(isConnected: true).assetName == "MenuBarIcon")
        let state = PullRequestSectionState(phase: .failed, result: result([pr(status: .changesRequested), pr("draft", draft: true)]))
        #expect(PullRequestInbox.authored.countText(in: state) == "1")
        #expect(PullRequestInbox.drafts.countText(in: state) == "1")
        #expect(PullRequestInbox.review.countText(in: .init()) == "—")
    }
}
