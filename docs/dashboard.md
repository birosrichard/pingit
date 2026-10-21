> Phase 4A adds independent current-head CI and PR diff totals to the existing
> discovery/refresh lifecycle. See [CI semantics and token limitations](checks.md)
> and [Phase 4A validation](phase-4a.md). Historical validation below remains unchanged.

> Phase 3F updates: structural limits now appear under neutral **Discovery info**.
> Observed truncation/conflicts show **Partial results**; errors show **GitHub needs
> attention**. Authored/draft rows use meaningful individual-review fallbacks for
> null decisions without changing the authoritative value. See
> [review mapping](reviews.md#dashboard-presentation-phase-3f) and
> [validation](phase-3f.md). Historical validation sections below describe earlier builds.

> Current Phase 3E behavior extends the Phase 3D implementation described below:
> the dashboard owns results per token and section, merging their union by node ID.
> A failed scope retains stale rows and a named error, while other scopes continue.
> Adding/replacing/removing invalidates outstanding responses and refreshes the new
> connection set; removal retains only remaining sources. See [current storage,
> lifecycle, merge policy and manual acceptance](tokens.md).
> The validation record below describes Phase 3D, not the current multi-token tests.

# Live pull request dashboard (Phase 3D)

The menu bar uses a full-width segmented navigation: **Review** (active direct requests),
**My PRs** (authored open PRs excluding drafts), and **Drafts** (authored drafts).
My PRs and Drafts filter the same aggregated cached result; their counts never
overlap. Counts show a dash before results arrive and retain the cached counts
on failure. Fetching, deduplication, cancellation and token handling are unchanged.

The popover is 440 points wide with opaque, system-aware header/footer and
contrasting content surfaces. Header, navigation and footer
stay visible; only the PR list scrolls, up to 360 points. Short lists shrink and
empty states use 180 points. Rows show a two-line title, repository and PR number,
relative update age (with a full-date tooltip), and either author or review summary. Hover highlighting, native Links and keyboard focus remain.
Approved does not establish merge readiness. Review and CI are separate indicators;
unknown review decisions use neutral activity fallbacks where supported, and absent CI data displays no CI indicator.
Discovery still does not fetch CI.

The footer shows an always-visible coverage/details button. Any error in either
query changes it to **GitHub needs attention**, even when another tab is selected.
Its tooltip and details popover retain named failures, repository coverage limits,
truncation and direct-only review semantics. Empty results are explicitly scoped to
token-visible repositories. Failed refreshes retain previous rows and timestamps.
Settings (⌘,), Quit (⌘Q), and Refresh (⌘R) remain native controls. The segment buttons support native keyboard focus and ⌘1 / ⌘2 / ⌘3 shortcuts.
Selected segments expose their selection state to accessibility.

## State and account lifetime

`GitHubConnection` owns one `PullRequestDashboard`, initialized with its existing
Keychain store and discovery client. A successful connect or restore starts a
clean dashboard session; no PR queries run until the popover appears. Opening
loads both sections concurrently. The same model survives closing the popover,
so in-flight work can finish and in-memory results display immediately on reopening.

Each section moves through idle, loading, loaded, or failed independently. A fast
section can display while the other is still loading. Refresh preserves previous
successful results and timestamps, clears previous errors, and replaces each
section only when its own discovery succeeds. Failure keeps old results visible
and labels them as previous results. No page-level partial success is invented.

A 60-second threshold since the last attempt avoids refetching on rapid openings,
including after errors. Explicit Refresh bypasses freshness; simultaneous refresh
is ignored and the button is disabled while either section loads. There are no
timers, background polling, automatic retry loops, or disk PR caches. A popover
left open updates row ages once a minute; this does not trigger network requests.
The footer retains the absolute last-success update time.

The credential loads once per refresh, stays outside observable state, and goes
only to the existing discovery services. Errors use fixed sanitized messages,
including connection attention, permission limitations, network errors, and rate
limits. An invalid discovery token prompts reconnecting in Settings; the dashboard
does not delete credentials or alter authentication behind the user's back.

Successful disconnect cancels the task and its child operations, clears both
sections, and invalidates the session synchronously, even with the popover closed.
A failed Keychain deletion preserves the connected session. Every response checks
its generation and cancellation before applying, so late responses cannot cross
a disconnect/reconnect, including reconnecting the same account. Each refresh also
has a new generation to keep older task cleanup from affecting a new refresh.

## Coverage and browser handling

- Token visibility notes appear for successful results, including empty lists.
  Neither account validation nor a successful query proves visibility of every repo.
- Direct-only coverage is structural: team review requests are unsupported. It is
  shown separately from errors and pagination truncation.
- Search/page/result/nested-request limits and unusable cursors produce incomplete
  result warnings. Discovery's underlying metadata is retained unchanged.
- Links use the API-returned URL. The browser boundary revalidates HTTPS,
  `github.com`, absence of credentials/port/query/fragment, and a canonical
  `/owner/repository/pull/number` path matching the PR number. Invalid links show
  an unavailable message and cannot be activated. Titles and repo names never
  construct destinations. No GitHub writes are implemented.

See [discovery](discovery.md) for permissions/bounds and [reviews](reviews.md) for
the distinction between overall decisions and individual reviewer details.

## Validation on 2026-10-21

- All **104 automated tests in seven suites passed**, including the existing 88.
  Mocks cover initial/empty/successful loads, both directions of partial section
  failure, independent completion, manual refresh, duplicates, freshness, retained
  data/timestamps on failure, cancellation, reconnect with a different or the same
  account, stale responses, coverage, sanitized errors, credential loading, failed
  disconnect, and unsafe/canonical browser destinations. No live credentials are
  needed by tests.
- arm64 Debug builds succeeded unsigned and with the existing development signing
  configuration, using Xcode 27.1 / Swift 6.4 in Swift 6 language mode, complete
  strict concurrency and Swift warnings as errors. Xcode emitted its standard
  AppIntents metadata-extraction notice because this app has no AppIntents dependency.
- Signed bundle/signature/sandbox/network/Keychain entitlement validation and launch
  smoke checks passed. SDK stat caching was disabled to avoid the existing SDK
  scanner stall. The compiler plugins/test runner required build-tool sandbox access.
- A user-supplied screenshot confirms a populated live authored section, an empty
  direct-request section, decoded Approved/unknown review decisions, and coverage
  notes. This verifies the returned data is displayed, not full repository coverage
  or a nonempty direct review case. No private PR titles, URLs, or credentials are
  stored as validation fixtures.
- Automated UI inspection was blocked: Computer Use was not approved to access
  pingit. No credentials were extracted into a shell/file to work around that.
- Xcode 26.3 compatibility, a new universal Release build, nonempty live direct
  requests, VoiceOver/keyboard activation, browser opening, and all token-visible
  repository comparisons were not validated in this pass.

## Remaining manual acceptance

1. Quit any old instance. Run the latest development-signed Debug build from Xcode,
   or open `build/Phase3DLive/Build/Products/Debug/pingit.app` after building it with
   the existing signing configuration. Use the normal app and Keychain credential;
   never copy the credential into a terminal. Settings must show the current account.
2. Open the popover. Compare **My pull requests** with GitHub search
   `is:pr is:open author:YOUR_LOGIN`, accounting for token-selected repositories and
   organization approval. Compare titles, draft state, ungrouped numbers, and each
   repository's review decision. Unknown is allowed; Approved is not merge readiness.
3. Compare **Needs your review** with
   `is:pr is:open user-review-requested:@me -author:YOUR_LOGIN draft:false`.
   Check a known active direct request if one exists. Team-only requests and completed
   requests must not qualify. Empty results alone cannot verify a nonempty case.
4. Activate a row with mouse and keyboard; confirm its canonical PR opens in the
   default browser. Check long titles, scrolling, light/dark, hover/focus, VoiceOver
   labels, ⌘R, Settings (⌘,), and Quit (⌘Q).
5. Refresh: verify progress, duplicate prevention, and retained rows. Rapidly reopen
   within 60 seconds; the previous timestamp should remain. After 60 seconds reopen
   and confirm refresh. Leave the app idle; it must not poll.
6. With results loaded, temporarily go offline and Refresh. Previous rows/timestamps
   should remain with an error. Restore networking and Refresh explicitly. Rate-limit
   errors should ask you to wait, without retrying repeatedly. Check permission and
   authentication errors only when those states occur; do not broaden organization
   access or exhaust rate limits just to manufacture a test.
7. Disconnect during loading in Settings. Return to the popover; no previous account
   data should appear. Reconnect (optionally using a different existing account's
   credential) and confirm a clean fetch. Restart to check saved-account restoration.

The next phase should be separately scoped: first close these live acceptance gaps,
then choose review/activity work (roadmap Phase 4) or read-only CI integration
(Phase 5). Neither is included in Phase 3D; polling and notifications remain deferred.


## Inbox redesign validation — 2026-10-21

- Debug build and all 142 tests in 11 suites pass with Swift 6, complete strict
  concurrency, and Swift warnings treated as errors. New tests cover exclusive
  draft filtering, loaded versus unavailable counts, cached results on failure,
  and compact relative-time boundaries including future timestamps.
- Bundle, signature, sandbox/network entitlement validation and the launch smoke
  test pass. Compiler plugins, the test runner and app launch required access
  outside the shell sandbox.
- User-provided screenshots of the running redesign confirm populated Review,
  My PRs and Drafts, long titles, mutually exclusive counts (11 + 4), scrolling,
  and persistent header/navigation/footer in light appearance.
- Computer Use access timed out, so direct interactive visual verification was
  unavailable. Dark appearance, empty/loading/error states, large counts,
  VoiceOver, keyboard activation and browser opening still need manual checking.
- Xcode emits its standard AppIntents metadata extraction notice because the app
  has no AppIntents dependency. No backend or API scope changes were made.

### Remaining visual checks

1. Run the latest build, inspect all three tabs in light and dark appearance,
   and use Tab/arrow keys to select segments and activate PR links. Check VoiceOver
   names, long repository truncation tooltips and full update-time tooltips.
2. Check an empty Review inbox: it should show “All caught up” with token-visible
   scope. Check many rows and large counts: only the list should scroll.
3. Press ⌘R: progress appears and Refresh is disabled while cached rows stay visible.
   Temporarily go offline and refresh: the footer must show GitHub needs attention,
   with details and previous results. Restore networking and refresh.
4. Open Discovery info: repository visibility and direct-only limits must be
   readable. Inspect any naturally occurring partial-token or authentication
   failure in the details panel and Settings; do not change token access to test it.


## Visual refinement pass — 2026-10-21

Compared the original reference image directly with the supplied running My PRs
screenshot. The three largest differences were the small floating navigation,
uniform gray surface, and undersized header/row typography. This view-only pass
replaces the stock picker with equally sized full-width segment buttons and count
badges, separates content from header/footer using opaque semantic system colors,
and strengthens the header and title hierarchy. Row margins align with the header;
metadata is now 12 points, titles 14, section headings 17, and the app name 20.
No data-fetching, token handling, cache or review semantics changed.

The Swift 6 Debug build, all 142 tests, bundle validation and launch smoke test
pass. Computer Use app access repeatedly timed out, so
no new screenshot was captured and the requested render/compare iteration remains
unverified. The supplied screenshots validate the earlier version only. Run the
latest build and capture Review / My PRs / Drafts in light and dark appearance to
verify the refined proportions, badges, contrast, focus, and long titles.
