# Phase 4C — Final dashboard UI/UX polish

Implemented on 2026-10-21. Focused presentation changes; the original fixed
440-point width, typography, avatar dimensions, three tabs, and refresh policy
remain in place. No new queries, dependencies, CI UI, or background work.

## Before and after

| Before | After |
| --- | --- |
| Rounded list surface with an outer border | Rows on the dashboard background with the existing subtle dividers |
| Nested padding placed avatars inside the section heading | Avatars align at the same 20-point leading inset as headings; dividers align with text |
| Trailing padding inside the document content | A native 12-point scroll-content margin reserves room beside content independently of scroll indicators |
| Low-contrast unboxed counts | Small neutral count badges, semibold monospaced digits, stronger selected count contrast |
| Orange Review required on draft PRs | No review prompt; diff alone when there are no submitted reviews, or the existing reviewer activity summary |
| Every metadata line assumed a review/author label | A missing draft review summary renders diff alone without an empty separator |

All tabs reuse the same row: 36-point avatar, 12-point avatar gap, 12-point row
padding, two-line title limit, baseline-aligned relative timestamp, and a 64-point
minimum full-row target. Actual text determines row height. The existing deliberate
horizontal-to-vertical metadata fallback remains. There are no metadata pills.

## Draft semantics and accessibility

Only a real draft in the Drafts inbox with GitHub's `reviewRequired` decision gets
the contextual suppression. With submitted reviews, the existing latest-review
summary presents approvals, requested changes, or comments. Without submissions,
there is no redundant Draft badge or review placeholder. Other review decisions,
including explicit approval and changes requested, retain their existing behavior.
Non-draft My PRs and Review author context are unchanged.

The PR's immutable `reviewStatus` and `latestReviews` are never modified. The full
row tooltip and VoiceOver summary retain the authoritative GitHub review metadata,
submitted-review details, draft lifecycle explanation, and full diff numbers.
Review metadata never establishes merge readiness. The activity summary's local
tooltip uses the full row explanation so that suppressing a draft review prompt
does not incorrectly imply GitHub supplied no authoritative decision.

Native Links, validated canonical URLs, keyboard focus outlines, hover backgrounds,
tab selection accessibility, and existing keyboard shortcuts remain. Counts and
accessible tab labels now use the same count formatter, including unknown `—` and
loaded-empty `0`. No animations were introduced.

## Scrollbars and bounds

The production ScrollView uses `.scrollIndicators(.automatic)` and
`.contentMargins(.trailing, 12, for: .scrollContent)`. AppKit chooses its standard
scrollbar behavior from the user's system preference, including overlay or legacy
scrollbars. The app does not force overlay style or change any system preference.
No custom scrollbar or AppKit introspection was added to production code.

The list remains bounded by measured content height, a 420-point maximum, and
available screen height. Header, navigation, section heading, and footer remain
outside the scrolling region. Removing the rounded clip also avoids cutting off
native scroll indicators. The popup cannot shrink below its original fixed width.

## Validation

- Full suite: **196 tests in 18 suites passed**. Existing authentication,
  multi-token isolation, discovery, refresh/lifecycle, reviews, diff, CI-domain,
  empty-state, canonical-link and accessibility tests remain intact.
- Focused additions cover draft review suppression without mutation, retained
  submitted approvals/changes/comments, unaffected other decisions, full accessible
  metadata, and exact unknown/empty/filtered tab counts.
- Signed **arm64 Debug build passed**. Effective settings: Swift 6.0,
  `SWIFT_STRICT_CONCURRENCY=complete`, `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`.
- Signed bundle/sandbox/networking/Keychain-entitlement/ATS validation and the
  two-second startup smoke check passed. The temporary launch instance was stopped.
- Swift compilation emitted no warnings. Xcode still emits its unrelated
  AppIntents metadata-extraction notice because no AppIntents framework is linked.
- Phase-wide whitespace and credential-pattern checks passed.

Build: `build/Phase4BSigned/Build/Products/Debug/pingit.app` (incremental build
directory reused from Phase 4B). Logs: `build/phase4c-signed-build.log`,
`build/phase4c-tests.log`, `build/phase4c-build-settings.log`.
Final test result:
`build/Phase4B/Logs/Test/Test-pingit-2026.10.21_17-17-07-+0200.xcresult`.
Validation above covers the Phase 4C UI through `28f0c9f`. A separate concurrent
commit, `d92b150` (background sync scheduling primitives), appeared in the shared
checkout afterward; it is preserved and is outside this phase's implementation
and validation report.

## Rendered visual verification and limitations

An isolated offscreen NSHostingView host compiled the production SwiftUI sources
with strict concurrency and warnings-as-errors. It rendered the complete dashboard
at 440 points using synthetic HTTP responses and an in-memory mock Keychain; no
real token, live PR query, or user Keychain was used. No window was ordered onto
the desktop. Temporary helpers and renders remain ignored under `build/`.

Before/after renders use the same fixtures; the baseline is commit `fa26321`.
Inspected all three populated tabs in light and dark appearance, plus representative
empty states. Checked short/two-line/truncated titles, long repository names, large
and unavailable diffs, retained draft approval, and consistent divider alignment.
The refinement pass retained accurate authoritative draft tooltip text and removed
empty punctuation from the accessible summary when draft review context is absent.

Fixture-only native scrollbar style checks exercise legacy and overlay layouts
without writing preferences. Native scroll/clip/scroller geometry was recorded;
content and timestamps remain inset from the trailing scroller area. The offscreen
captures do not establish live scrollbar fade/paint behavior or user interaction.

Examples:

- `build/phase4c-before-populated-drafts-light-440.png`
- `build/phase4c-after-populated-drafts-light-440.png`
- `build/phase4c-after-populated-review-light-440.png`
- `build/phase4c-after-populated-authored-dark-440.png`
- `build/phase4c-after-empty-drafts-light-440.png`
- `build/phase4c-legacy-populated-drafts-light-440.png`
- `build/phase4c-overlay-populated-drafts-dark-440.png`

Computer Use was not authorized for this phase and was not used. Live MenuBarExtra
mouse/trackpad/keyboard scrolling, browser activation, hover/focus interaction,
VoiceOver, and system-preference switching were not manually exercised. Their
existing native implementations remain, but this report does not claim interactive
acceptance or real-account/Keychain revalidation.

## Implementation commits

- `15e70f7` — simplify list surface and native scroll spacing
- `b227381` — improve tab counts and draft presentation
- `da79b5b` — focused presentation tests
- `28f0c9f` — accurate draft review help and accessibility refinement

Documentation is committed separately. No push or pull request. Unrelated
`artwork/website/` content is untouched.
