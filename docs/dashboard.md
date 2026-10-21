# Live pull request dashboard (Phase 3D)

The menu bar shows **Needs your review** (active direct requests) and **My pull
requests** (authored open PRs, including drafts). Each section has its own loaded
count, progress, last-success timestamp, empty state, error, and coverage notes.
Rows show title, repository, ungrouped PR number, draft state, and either author
or GitHub's authoritative review decision. Approved does not mean merge-ready.
Unknown decisions remain explicitly unknown; CI is not fetched.

The native SwiftUI popover is 380 points wide with a 440-point scrolling content
area, system typography/colors, two-line title truncation, native Links, hover
feedback, and accessibility labels. Settings and Quit remain available; Refresh
also supports ⌘R. macOS keyboard navigation settings determine Tab traversal of
native controls. Light/dark, focus, VoiceOver, and browser activation require a
manual acceptance pass.

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
left open displays the absolute last-success timestamp without a timer updating it.

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
