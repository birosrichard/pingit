> Phase 3E: each method below is invoked separately for every configured token.
> Pagination bounds and errors remain per token. The dashboard schedules up to two
> token scopes concurrently and merges their node IDs within each semantic section.
> See [aggregation and merge policy](tokens.md). Coverage never implies all owner repositories.

# Pull request discovery (Phases 3B–3D)

`GitHubPullRequestDiscovery` fetches data on explicit invocation. The Phase 3D
dashboard calls it on popover opening or manual Refresh, using a 60-second freshness
window without timers. Supply the `GitHubAccount` already validated
by `GitHubConnection` and the token loaded from the existing Keychain store. The
service does not retain credentials, change authentication, or invalidate tokens.
The `viewer.login` in every page must match the supplied account; a mismatch fails
with `GitHubDiscoveryError.accountMismatch`. No username is hardcoded.

## Queries and selection

Both methods use GraphQL `search(type: ISSUE)` with PR-only search qualifiers:

- Authored: `is:pr is:open author:<validated-login> sort:updated-desc`. Includes drafts.
- Requested: `is:pr is:open user-review-requested:@me -author:<validated-login> draft:false sort:updated-desc`.
  Returns **direct** review requests only, excluding drafts and the user's own PRs.

[GitHub documents these search qualifiers](https://docs.github.com/en/search-github/searching-on-github/searching-issues-and-pull-requests),
including the difference between pending review requests and historical review
involvement. Assignees are never used. The DTO state/author/draft fields are checked
again in case the search index lags. Review results must also contain an active
`reviewRequests` entry for the viewer, so a submitted/removed request is filtered
out even if its search hit remains. A new request to a previous reviewer is valid;
no blanket `-reviewed-by` exclusion is used.

Team review discovery is not implemented. GitHub supports `review-requested:<login>`
(includes team requests), `team-review-requested:<org/team>`, and
`team-review-requested-user:<login>` (teams only). These are possible follow-ups,
not guarantees of this implementation. We do not enumerate organizations or teams,
request Members permission, or infer team membership from an assignee or review
history. `coverageLimitations` includes `directReviewRequestsOnly` for every review
result. A PR that requests both a team and this user directly still qualifies.

The common transport DTO decodes required fields strictly and maps to domain values
outside SwiftUI. It preserves node IDs, repository identity, number, title, URLs,
creation/update dates, author and draft state. Deleted authors/reviewers are nullable.
Timestamps accept ISO-8601 with optional fractional seconds. Missing required fields,
invalid dates/URLs or node shapes fail explicitly; a null search node is `missingData`.
A missing review-request connection is `partialData`, not a fulfilled request.
Both discovery queries also retrieve overall review decisions and bounded latest
reviewer details. Missing decisions become unknown; CI stays nil. No state is
inferred from approval counts. See [review semantics and limitations](reviews.md).

## Bounds and completeness

The default maximum is 200 unique PRs; callers may request 1–1,000. Invalid limits
fail before networking. Each call requests at most 50 search hits per page, shrinking
to the remaining result budget. There are independent hard bounds of 20 search
requests and 1,000 scanned hits. Duplicate or stale hits cannot cause unlimited work.

Pagination follows `hasNextPage` and `endCursor`. Node IDs deduplicate within/across
pages, keeping the first observed value. Returned PRs sort by descending `updatedAt`,
with encounter order preserved for ties. GitHub's
[updated-date search sorting](https://docs.github.com/en/search-github/getting-started-with-searching-on-github/sorting-search-results)
is also requested server-side. Search is a live index, not a consistent snapshot;
concurrent updates can move or omit hits across pages. Deduplication cannot recover
omitted hits. There is no automatic retry or date-range search partitioning.

`truncationReasons` explains incomplete results:

- `resultLimit`: the caller's unique-result budget was reached with more pages.
- `pageLimit`: the request bound was reached with more pages.
- `searchLimit`: the count exceeds GitHub's cap, or 1,000 hits were scanned with more pages.
- `invalidCursor`: a next cursor is missing, empty or repeats an earlier cursor.
- `reviewRequestLimit`: a nested review-request list has more than the requested 100 entries.

[GitHub caps search at 1,000 hits](https://docs.github.com/en/graphql/reference/search),
regardless of the reported count. Even if the last page says `hasNextPage: false`,
a reported count above that cap marks the result truncated.

Nested review requests are deliberately bounded to one page of 100 per PR. When
truncated, a visible direct request can still establish eligibility, but the domain
`reviewRequests` stays nil. If the user's request is not in that page, the PR is
omitted and `reviewRequestLimit` makes the uncertainty explicit. No false claim of
a complete reviewer list is made. Null/deleted reviewers are omitted from mapped
requests; teams with visible metadata are mapped as teams, not users.

Cancellation propagates from before networking, during URLSession, and between pages
and mapped nodes. A failed page throws the existing sanitized API error and fails the
whole operation; previously collected pages are not returned as a successful result.
This includes unauthorized, forbidden, rate-limit, network, malformed-body and
GraphQL/partial-data failures. The caller may retry explicitly. No token or raw server
error is included in discovery errors.

## Permissions and repository visibility

Use a fine-grained PAT with read access only:

- Public repositories are readable through the token's built-in public access.
- For private repositories, select the required repositories and grant **Pull requests:
  Read-only**; repository **Metadata: Read-only** accompanies selected repository access.
- Organization repositories require that organization as resource owner, the user's
  own repository access, allowed PAT policy and any required organization approval.
  Pending tokens can read only public resources. A token cannot expand the user's access.
- One fine-grained PAT cannot cover private repositories across multiple resource
  owners. Organization outside-collaborator support also has documented limitations.

These rules come from GitHub's
[fine-grained PAT documentation](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).
The [requested-reviewer API](https://docs.github.com/en/rest/pulls/review-requests#get-all-requested-reviewers-for-a-pull-request)
and [PR API](https://docs.github.com/en/rest/pulls/pulls#get-a-pull-request) document
Pull requests read permission for those resources. The GraphQL client uses the same
PAT and only requests PR/repository metadata, latest review states and active review
requests. No Contents, Issues, Checks, Actions, Members or write permission is requested
by this feature.
Live GraphQL access for a particular organization still needs a signed-app/token
acceptance pass; REST permission references are not a live permission probe.

Every result, including an empty one, carries `coverageLimitations: [.tokenVisibility]`
(and direct-only coverage for review results). Search can silently exclude repositories
outside token selection, the resource owner or approval/access policy. Neither a
successful `/user` response nor an exhausted search proves global PR coverage. There
is no permission inventory endpoint used here, so the service cannot reliably tell
whether an empty search means no PRs or restricted visibility. Consumers expose
that limitation in neutral discovery information even when `isTruncated` is false;
structural scope alone does not produce a warning. Explicit permission errors propagate
rather than becoming empty lists. Existing saved tokens are not upgraded automatically.

## Validation and next phase

All tests use isolated URLProtocol sessions; no live credential or user Keychain is
required. Phase 3B passed all 77 tests in six suites and an arm64 Debug build with
Swift 6 strict concurrency and warnings as errors (Xcode 27.1). Live GitHub, signed
Keychain access and universal Release were not validated. Cases cover queries, DTO
validation, null authors, fractional dates, draft
rules, direct/fulfilled/team requests, empty visibility-limited results, cursor and
nested limits, deduplication/order, permission/API errors and cancellation on page two.

Phase 3D adds the cancellable dashboard state layer and native menu bar UI, exposing
both lists, errors, timestamps, truncation, and coverage. See [dashboard](dashboard.md)
for current validation and remaining live acceptance. Team discovery still needs its
own scope, tests, and access/visibility policy. CI aggregation, activity
tracking, polling and notifications stay deferred.

## Coverage presentation (Phase 3F)

The domain metadata above is unchanged. `DiscoveryCoveragePresentation` interprets
both dashboard sections so a problem remains visible from every tab:

- **Discovery info**, secondary text and an info icon: successful discovery with
  token visibility/direct-only limitations. Details retain both structural notes;
  this never claims GitHub-wide coverage.
- **Partial results**, orange warning icon: search/page/result/review-request bounds,
  unusable cursors, or conflicting token metadata in either section.
- **GitHub needs attention**, orange warning icon: connection or section errors,
  including rate limits and API failures. Named per-token errors and stale results
  remain available. This also works when no result has ever succeeded.

The help and VoiceOver label contain the warning and its actual reasons. A successful
refresh replaces old coverage metadata and clears transient errors; the current
refresh/caching policy is unchanged. Per-PR reviewer truncation is described in that
row's review tooltip, independently of discovery truncation.
