# Phase 4B — Native dashboard UX refinement

Implemented on 2026-10-21 (Europe/Prague). This phase changes native presentation,
not authentication, GitHub queries, PR discovery, CI normalization or refresh policy.

Follow-up: restored the original fixed 440-point popover width after the flexible
frame allowed the live menu-bar window to become too narrow. The comparison and
rendering notes below describe the initial Phase 4B implementation.

## UI changes and comparison with the reference

The supplied concept establishes a strong header, clear navigation, a separated PR
surface and compact metadata. Its physical pixel dimensions and example content are
not copied. The actual supplied screenshots establish the Phase 4A baseline.

| Before | Phase 4B |
| --- | --- |
| Dense four-line rows with repeated CI labels | One shared row; title, repository, compact review/author + diff metadata |
| 440-point width and cramped metadata | Up to 460 points, responsive to the available screen; 360-point fixture checked |
| Small fixed-size metadata | Native title3 semibold titles, callout repository/metadata, subdued caption timestamps |
| Review and diff occupy separate lines | One line where it fits; a vertical fallback handles narrow layouts and long context |
| Review-row author avatars vary in meaning | Repository owner identity in every inbox using the existing validated avatar mechanism |
| Large generic fallback image | Consistent 36-point avatar frame with an inset native repository symbol |
| Repeated tab/section wording and decorated count pills | Contextual headings; compact unboxed counts and a restrained segmented appearance |
| Estimated list height can leave empty space | Measured content height for short lists; bounded 420-point scroll region for long lists |
| Scroll offset can carry across tabs | A changed tab recreates only the scroll view and starts at the top |
| CI unavailability causes frequent Partial results | Unavailable CI alone stays out of dashboard warnings; actual discovery problems still warn |

The header retains app icon/name, one username, configured **token** count and
Refresh. This application still represents one GitHub identity, not multiple
accounts. Navigation retains Review / My PRs / Drafts and their exclusive counts.
Context headings are Requested from you, Open pull requests and Work in progress.
The native list uses one subtle grouped surface and aligned dividers; rows have
no decorative cards or pills. Long titles use two lines; repository text truncates
in the middle and keeps its full value in help and accessibility.

The header, navigation and footer stay outside the only PR ScrollView. Its content
reserves a trailing scrollbar gutter. A small local geometry preference measures
height without touching discovery state. The screen-height bound leaves room for
popover chrome. No scrolling window, nested PR scroll view or background work is
introduced. Loading, empty, disconnected and failed states remain distinct. Initial
loading has one central progress indicator; refresh of existing data retains a
header indicator. Footer Settings/Quit, last update, details and genuine warnings
remain visible.

Rows retain canonical validated GitHub Links. Hover treatment and explicit keyboard
focus outlines use native semantic colors without animations, including reduced
motion. Existing Command-R, Command-1/2/3, Settings Command-comma and Quit Command-Q
remain. Left/right arrow handling is added within focused tab navigation. No new
row actions or context menus exist. Interactive verification remains pending below.

## CI visibility and review semantics

All CI states are hidden from default PR rows: passing, failing, pending, cancelled,
skipped/neutral, unavailable and no checks. They are also absent from row help and
VoiceOver output. `PullRequestRowPresentation` does not depend on the CI snapshot;
a deterministic test verifies identical output for all seven normalized CI states.

Phase 4A query fields, parsing, normalization, current-head guards, multi-token merge,
raw coverage metadata and all CI tests remain intact. This keeps the work available
for a future separately scoped GitHub App authentication decision. There is no new
authentication mechanism or GraphQL discovery feature in Phase 4B.

The `checkDataUnavailable` limitation is no longer a dashboard warning or contextual
CI explanation. It remains in each source's raw result. Truncation, conflicting PR
metadata, authentication, HTTP/GraphQL discovery failures and named per-token errors
remain visible. The Phase 4A optional-CI-subtree recovery policy is unchanged; a
failure that prevents PR discovery is not silently converted into success.

Authoritative GitHub review decisions and Phase 3F fallback summaries are unchanged.
Approved and Changes requested retain meaningful semantic color. Ordinary missing
review information remains neutral. Draft identity is conveyed by its tab/context
and the row accessibility description, without a repeated Draft badge on each row.
Review approval never claims merge readiness. Diff totals remain visible everywhere,
using singular/plural file labels, semantic additions/deletions, compact numbers
and full integer VoiceOver descriptions. Missing totals are never fabricated zeroes.

## Files changed

- `pingit/Features/MenuBar/MenuBarView.swift`: composition, navigation/focus, sizing,
  scrolling, footer and state rendering; CI row output removed.
- `pingit/Features/MenuBar/PullRequestRow.swift`: one reusable native row and link,
  hover/focus, aligned identity/time, adaptive metadata and owner fallback.
- `pingit/Features/MenuBar/PullRequestPresentation.swift`: testable row/empty-state
  projections and a small dashboard spacing/sizing helper, without a web theme system.
- `pingit/Features/Settings/GitHubAccountView.swift`: reuse existing avatar loading
  with a configurable native fallback and consistent inset. No extra endpoint or
  decorative API request is introduced.
- `pingit/Core/GitHub/GitHubPullRequest.swift`: share existing relative-age formatting
  with the presentation model; behavior and boundary tests remain unchanged.
- `pingit/Core/GitHub/PullRequestDashboard.swift`: presentation-only coverage filtering;
  no fetch, caching, cancellation or aggregation lifecycle changes.
- `pingitTests/DashboardPresentationTests.swift`, `PullRequestDashboardTests.swift`,
  `GitHubPullRequestDiscoveryTests.swift`: focused presentation/policy tests and
  updated UI-only coverage expectation, retaining raw CI parsing assertions.
- `pingit.xcodeproj/project.pbxproj`: register the new source/test files in existing
  targets. Signing configuration, app capabilities and dependencies are unchanged.
- README, architecture, roadmap, dashboard and CI documentation: current policy,
  validation and historical-record clarification.

Unrelated untracked `artwork/website/` was present at the start and remains untouched.
No production example PRs, private screenshot content or credentials were added.

## Test and build results

- **192 tests in 18 suites passed**, retaining the prior 183 tests and adding nine
  focused presentation/coverage tests. Parameterized cases cover all inboxes and CI
  states. Coverage includes canonical/unsafe links, repository identity, mutually
  exclusive author/review context, review semantics, full accessible diff counts,
  draft identity, missing images/diff, large numbers, empty/loading/failed states,
  screen bounds, measured heights, and preserved real discovery failures.
- Apple Development-signed **arm64 Debug build passed** with the existing app
  identity, profile, signing team and private Keychain group.
- Swift 6 language mode, complete strict concurrency and Swift warnings as errors
  remain enabled. The independent native fixture host also compiled the production
  sources with explicit `-strict-concurrency=complete -warnings-as-errors`.
- Strict signature, bundle, sandbox, outbound-network, Keychain entitlement/profile
  policy and ATS validation passed. The two-second signed launch smoke check passed
  and stopped only its temporary instance.
- Xcode's standard AppIntents metadata extraction notice remains because the app
  has no AppIntents dependency. No Swift compiler warnings were emitted.
- Phase-wide Git whitespace, credential-pattern and documentation-link checks passed.
  No push, PR creation, dependency installation or GitHub mutation occurred.

Commands:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase4B \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES SDK_STAT_CACHE_ENABLE=NO test
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase4BSigned \
  SDK_STAT_CACHE_ENABLE=NO build
sh scripts/validate-app.sh build/Phase4BSigned/Build/Products/Debug/pingit.app
sh scripts/validate-launch.sh build/Phase4BSigned/Build/Products/Debug/pingit.app
```

Build: `build/Phase4BSigned/Build/Products/Debug/pingit.app`.
Final test result: `build/Phase4B/Logs/Test/Test-pingit-2026.10.21_17-00-22-+0200.xcresult`.
Logs: `build/phase4b-tests.log`, `build/phase4b-signed-build.log`.

## Visual verification evidence

Actual live menu-bar capture was attempted through Computer Use using both the app
name and the final signed app path. Both calls returned `timeoutReached` (-10005).
No permission was bypassed and no alternate desktop automation was used. Therefore
this phase does **not** claim interactive live-popover acceptance.

Visual verification did inspect rendered UI, rather than only SwiftUI source:
an isolated local `NSHostingView` fixture host compiled the production MenuBarView,
PullRequestRow, account/dashboard and settings sources. It supplied two synthetic
in-memory connections through mocked HTTP and mocked Keychain operations. There
was no real PAT or user Keychain access. The temporary offscreen host rendered the
complete native hierarchy, including ScrollView and native footer controls. No
window was ordered onto the user's desktop. An initial ImageRenderer attempt was
insufficient because it omitted native views; those incomplete images were not
used as acceptance evidence.

The first complete native render was compared with the supplied reference and
baseline screenshots. It revealed excess height below short lists, oversized
fallback symbols and overly faint timestamps. The refinement pass measured actual
content height, inset the fallback, improved timestamp contrast and removed the
duplicate initial-loading spinner. Final renders were inspected for populated
Review/My PRs/Drafts, long two-line titles, long repository truncation, large/zero
and unavailable diff totals, neutral unknown review, approved/changes requested,
loading, empty, failed/disconnected, real partial-discovery warnings, light/dark
appearance and 360/460-point layouts. No horizontal overflow was observed; narrow
metadata wraps while the footer remains outside the bounded scroll view.

Representative final local PNGs (synthetic data):

- `build/phase4b-final-populated-review-light-460.png`
- `build/phase4b-final-populated-authored-light-460.png`
- `build/phase4b-final-populated-authored-dark-360.png`
- `build/phase4b-final-populated-drafts-dark-460.png`
- `build/phase4b-final-empty-review-light-460.png`
- `build/phase4b-final-loading-review-light-460.png`
- `build/phase4b-final-failure-review-light-460.png`
- `build/phase4b-final-partial-review-light-460.png`
- `build/phase4b-final-disconnected-review-dark-460.png`

The fixture helper and images stay in ignored `build/`; they are not shipped, and
no snapshot infrastructure or third-party dependency is added to the app/tests.
These renders verify geometry and visual states, not pointer/keyboard interaction,
VoiceOver behavior or the MenuBarExtra window itself.

## Remaining acceptance and recommended next phase

1. Quit the older running pingit instance, then launch the signed Phase4BSigned app
   above. Open each tab using real saved connections. Confirm titles, meaningful
   owner avatars, context/diff metadata, count accuracy and no CI labels/tooltips.
2. Scroll a long list, switch tabs and verify the new tab starts at its top. Header,
   tabs, context heading and footer should stay fixed; the scrollbar must have room.
   Check one/few/many rows, long names, light/dark and increased-contrast settings.
3. Use Tab, arrow keys and Command-1/2/3; verify focus outlines and PR activation.
   Test Command-R, Settings Command-comma and Quit Command-Q. Use VoiceOver to
   confirm full PR/review/diff descriptions without hidden CI content.
4. Refresh loaded data: rows should remain, Refresh is disabled, and the header
   indicates progress. Reopening within 60 seconds should not add another request.
   Verify empty/loading/offline/authentication and real partial-token cases when
   naturally available. CI unavailability alone must not raise Partial results;
   discovery failures must still appear. No background polling should occur.

Interactive hover/focus/scrolling/browser activation and VoiceOver are unverified
because live app access timed out. Private personal/Apify PAT coverage, live account
management, Intel/universal Release and older Xcode were not revalidated; their
architecture is unchanged. Native fixture colors/fonts reflect the installed SDK
and do not prove rendering on every supported macOS release.

Recommended next phase: finish this signed-app live interaction/accessibility pass.
Choose any GitHub App authentication/CI return separately. Background polling,
notifications and other deferred features were not started.

## Incremental commits

- `0148808` — hide default CI rows/help and unavailable-CI-only warnings, retain CI infrastructure.
- `d60c713` — reusable native row/projection, hierarchy, tabs, owner identity and focused tests.
- `d01317b` — visual refinement: measured list height, contrast, fallback scale and loading indicator.
- Documentation is recorded in a separate final commit; use `git log` for its hash.
