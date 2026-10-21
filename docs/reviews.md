# Pull request review status (Phases 3C–3F)

## Overall decision

Both discovery methods batch `reviewDecision` and `latestReviews(first: 50)` into
the existing search query. No per-PR requests or complete review histories are fetched.
`GitHubPullRequest.reviewStatus` maps GitHub's `APPROVED`, `CHANGES_REQUESTED`, and
`REVIEW_REQUIRED` to their corresponding domain cases. Null, missing, and future
unsupported decisions become `unknown`. A nil domain status remains available for
older/not-loaded domain values; discovery always supplies a status.

Only GitHub's decision determines the overall state. Individual approvals, review
requests, comments, and an empty reviewer list never supply a fallback decision.
Unknown does not mean no reviews are required. Approved does not establish merge
readiness; CI, conflicts, and other repository requirements are outside this phase.

## Individual reviews

`latestReviews` is GitHub's latest non-pending review per user, not an effective
branch-protection vote ledger. Superseded submissions are excluded by that server
connection; the app does not fetch, count, or reduce historical reviews. In particular,
a latest comment is informational and cannot prove whether a previous opinion still
satisfies repository rules. `latestOpinionatedReviews` is another per-user connection,
but it is not a substitute for the overall decision or a full latest-review display.
`reviewRequests` continues to represent active requests separately from submissions.

`GitHubPullRequest.latestReviews` contains review IDs, nullable author logins, and
normalized states: approved, changesRequested, commented, dismissed, pending, or
unknown. Dismissed and commented reviews never become approvals. Pending is modeled
defensively but the queried connection excludes pending submissions. Unsupported
states map to unknown and mark details incomplete. Missing authors retain their
review without inventing an identity or combining deleted accounts.

The details carry explicit `limitations`: `unavailable` for a null/missing connection
or node list, `reviewerLimit` for another page, `missingReview` for null entries,
`missingIdentity` for null/empty logins, and `unknownState` for unsupported states.
Available entries are retained alongside these flags. A known empty list has no
limitations; it differs from unavailable details. Completeness concerns the visible
latest non-pending reviews only, never token-wide repository visibility.

The nested reviewer page is intentionally not paginated. At most 50 reviews per PR
and 50 search hits per page are requested (at most 2,500 review nodes per search
page). Existing search pagination, active-request bounds, result deduplication, and
cancellation remain intact. Details truncation is per PR and does not mean
that search itself was truncated. No review bodies or comments are fetched.

## Rules and permissions

GitHub's [GraphQL PR schema](https://docs.github.com/en/graphql/reference/pulls)
documents the nullable decision/review connections, latest-per-user semantics,
active review requests, and review state enums. GitHub's
[branch protection](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches)
and [rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)
can require approval counts, code owners, dismissal of stale approvals, and approval
of the most recent push. We do not reconstruct these policies or fetch their settings.
The API does not explain every null decision; the app cannot distinguish absent
requirements from unavailable information using these fields alone.

The existing PAT and repository visibility limits still apply; see
[discovery](discovery.md). A null review connection without GraphQL errors becomes
unavailable details. Explicit field permission errors retain the client's all-or-fail
behavior: data plus errors throws sanitized `partialData`, and errors without data
throw `graphQLFailure`. No partial page or earlier pages are returned as success.
A failed review field is never silently treated as an empty/approved result.

## Validation

Phase 3C passes all 88 tests in six suites (including the previous 77) and an
unsigned arm64 Debug build with Xcode 27.1, Swift 6, complete strict concurrency,
and Swift warnings treated as errors. The initial sandboxed run could not execute
Swift macro plugins; validation succeeded with the required build-tool access.

Mocked tests cover overall mapping, reviewer states, superseded selections, missing
identities/connections/nodes, truncation, discovery pagination, GraphQL failures,
and cancellation. They use no credentials or real Keychain data.
The validation path uses unsigned builds and an unhosted test bundle, so it does
not exercise the provisioned app's Keychain entitlement. Live app-token visibility,
private organization access, and permission behavior were not validated here and
still need a signed-app acceptance pass.
No credential was extracted into a shell or a file for validation.

## Dashboard presentation (Phase 3F)

`PullRequestReviewPresentation` supplies compact row labels, semantic icons/colors,
and the same detailed description for help and accessibility. It never mutates
`reviewStatus`. My PRs and Drafts show the review summary; Review retains its author
metadata. The layout is unchanged.

| GitHub overall decision | Latest reviewer activity | Row label |
| --- | --- | --- |
| APPROVED | Any | Approved |
| CHANGES_REQUESTED | Any | Changes requested |
| REVIEW_REQUIRED | Any | Review required |
| Unknown/null | Complete, empty connection | No reviews yet |
| Unknown/null | Identifiable approval(s) | 1 approval / 2 approvals |
| Unknown/null | Identifiable approval(s), incomplete details | At least 1 approval / At least 2 approvals |
| Unknown/null | Identifiable changes requested, including mixed approvals | Changes requested by reviewer |
| Unknown/null | Comments, without approvals or changes requested | Review comments |
| Unknown/null | Unavailable/empty incomplete details, dismissed/pending/unknown states only, or missing identities only | No review decision |

Approval counts deduplicate reviewer logins case-insensitively. Bots are included:
`author { login }` uses GitHub's Actor interface, which includes Bot, with no User-only
fragment or login validation in review mapping. Both `macroscopeapp` and a login
ending in `[bot]` survive decoding. Missing identities remain in domain details but
are not counted as identifiable approvals. Dismissed, superseded, pending and unknown
states do not supply approvals. An empty list is considered empty only when its
limitations are empty; it never implies that repository rules require approval.

Fallback approvals use neutral color and an outline review bubble, distinct from
GitHub's authoritative Approved status. Tooltips expose mixed activity and incomplete
details and explicitly avoid a merge-readiness claim. Individual review activity
is not an effective branch-protection vote ledger.

Same-snapshot token merging preserves compatible incomplete review lists by unioning
review IDs and limitations. It does not manufacture completeness. Complete supersets
replace incomplete subsets; unavailable details yield to available details. Contradictory
states/IDs for the same reviewer remain a conflict and hide the ambiguous list for
that merge, including when a third token agrees with one side. Older snapshots do
not fill newer review data. See [token merge policy](tokens.md).

No production query or API-request count changed in Phase 3F. See
[Phase 3F validation](phase-3f.md) for fixtures, live connector results, and limits.
