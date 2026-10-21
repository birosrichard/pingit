# Phase 3F — Review status and coverage UX

Completed on 2026-10-21. This phase changes review/coverage presentation and a
same-snapshot review-detail merge case. Authentication, scopes, queries, request
counts, refresh policy, layout, CI, notifications and GitHub writes are unchanged.

## Implementation

- Structural coverage limitations remain in the discovery domain and details panel.
  They now show neutral **Discovery info**, not a persistent warning.
- Truncation and conflicting token metadata show **Partial results**. Connection,
  API and rate-limit failures show **GitHub needs attention**, including when no
  results exist. Errors retain their section/connection names. Problems in either
  section remain visible from every tab. Help and VoiceOver include actual reasons.
- Successful refreshes replace old metadata and clear transient warnings. Previous
  rows and per-connection details remain available on failures.
- `PullRequestReviewPresentation` drives row text, icons, semantic colors, tooltips
  and accessibility. GitHub's authoritative review decision always takes precedence.
  Individual approvals never change `reviewStatus` or establish merge readiness.
- Compatible incomplete latest-review lists from matching PR timestamps now combine
  unique review IDs and limitation flags. Complete supersets still win over partial
  subsets. Contradictory reviewer observations remain unknown with a coverage warning;
  a third token cannot erase the conflict. Older snapshots never fill newer details.

## Review mapping

| Overall decision | Available latest reviews | Label |
| --- | --- | --- |
| APPROVED | Any | Approved |
| CHANGES_REQUESTED | Any | Changes requested |
| REVIEW_REQUIRED | Any | Review required |
| Unknown/null | Complete empty connection | No reviews yet |
| Unknown/null | Identifiable approvals | 1 approval / N approvals |
| Unknown/null | Approvals with incomplete details | At least N approvals |
| Unknown/null | Changes requested, including mixed approval/change states | Changes requested by reviewer |
| Unknown/null | Comments without approvals/changes requested | Review comments |
| Unknown/null | Unavailable, incomplete empty, dismissed/pending/unknown only, missing identity only | No review decision |

Mixed activity is exposed in the tooltip. Fallback approvals use neutral color and
an outline bubble. Counts deduplicate reviewer logins case-insensitively. Missing
identities remain in the domain but do not supply identifiable approval counts.

## GraphQL and normalization findings

The existing `latestReviews(first: 50)` query already requests `id`, `state`,
`author { login }`, and `pageInfo`. Bot review retrieval needs no extra fields or
requests. GitHub's [Actor interface](https://docs.github.com/en/graphql/reference/users#actor)
includes Bot and exposes its login. Fixtures cover both a plain bot login and a
`[bot]` suffix. The avatar login validator is unrelated to review decoding.

GitHub documents [latestReviews](https://docs.github.com/en/graphql/reference/pulls#pullrequest)
as latest non-pending reviews per user. Historical submissions do not enter this
normalization. Dismissed, commented, pending and unknown states remain distinct and
never supply approvals. The 50-review bound, null nodes, missing identities,
unavailable details and unsupported states retain their existing limitation flags.
Review completeness does not establish repository-wide discovery completeness.

## Live validation

Read-only GitHub connector checks on 2026-10-21:

- `pingdotgg/t3code` PR #21678: metadata was accessible and the review-list operation
  returned an APPROVED submission with normalized author login `macroscopeapp`.
- `birosrichard/reviscan` PR #13: the connector returned REST 404 and GraphQL
  repository NOT_FOUND. This establishes only that the connector cannot access it.

The connector's metadata/review tools do not expose the app's exact `reviewDecision`,
`latestReviews` connection or its pageInfo. Those live values and normalized app
coverage therefore remain unverified. The T3 Code result verifies a submitted bot
approval, not the exact latest-review response or the overall decision. No app PAT
was extracted, no credential printed, and no PR modified. Deterministic fixtures
cover both null-decision acceptance scenarios without hardcoded production PR data.

## Validation

- Full suite: **155 tests in 13 suites passed** using mocked networking and isolated
  credential storage. Coverage includes all prior cases plus empty/null decisions,
  bot/multiple approvals, changes/comments/mixed states, dismissed/pending/unknown
  states, superseded approvals, missing identities, bounded details, authoritative
  precedence, token-order permutations, complementary details and sticky conflicts.
- Coverage tests verify structural-only success, every truncation reason, connection
  failure and rate limiting, mixed successful/failed scopes, VoiceOver descriptions,
  and clearing a transient failure after a successful refresh.
- Development-signed **arm64 Debug build passed**, Xcode 27.1 / Swift 6.4 compiler,
  Swift 6 language mode, complete strict concurrency, Swift warnings as errors.
  The only build notice is Xcode's standard AppIntents metadata extraction warning
  for an app without an AppIntents framework dependency.
- Signed bundle/signature, sandbox, network and Keychain entitlement policy checks
  and the two-second launch smoke check passed. Certificate trust validation needs
  build-tool access outside the shell sandbox; the sandboxed check reported
  CSSMERR_TP_NOT_TRUSTED. The same check passed with system trust-service access.
- Diff whitespace checks and credential-pattern scans of the phase changes passed.
  No signing/project formatting changes were made. Initial working tree was clean.
- Build outputs: `build/Phase3FSigned/Build/Products/Debug/pingit.app`; test results
  under `build/Phase3F/Logs/Test/`. SDK stat caching was disabled for validation.

## Limits and next phase

Team requests and token-invisible repositories remain structural limitations.
Latest reviews are bounded activity, not an effective approval-policy ledger;
conflicting observations remain conservatively unavailable. No new API requests
were introduced. Exact live app-token scenarios, visual layout in light/dark mode,
VoiceOver interaction and keyboard/browser activation were not manually verified.
Intel/universal Release and Xcode 26.3 were not rebuilt in this focused phase.

Next: a signed-app acceptance pass for the two PR scenarios, light/dark appearance,
and VoiceOver/keyboard interaction. Then scope read-only CI integration separately;
polling, notifications and team discovery remain deferred.
