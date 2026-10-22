# Phase 7A — Attention & Review Prioritization

Attention is a deterministic interpretation of existing normalized discovery data.
It introduces no API queries, timer, dependency, database, telemetry, GitHub writes,
private-content persistence, activity feed, or notification event. Conversation and
lifecycle queries retain their existing behavior and budgets.

## Classifications and precedence

`PullRequestAttention` and `PullRequestAttentionReason` are SwiftUI-independent,
Sendable domain values. There are four classifications and no priority scores:

1. **Unknown** gates every classification when the section is unverified, loading,
   failed, truncated, or contains conflicting token metadata. Retained omitted rows
   are explicitly previous data. Missing identity or required review evidence is
   also unknown. Unknown never implies action or waiting.
2. **Work in progress** applies to a currently verified authored draft. A draft
   never becomes an active review request, even with a changes-requested decision
   or a direct request. A draft by another author stays unknown.
3. For an authored, non-draft PR, GitHub's authoritative overall
   `CHANGES_REQUESTED` decision means **Needs attention**, with typed reason
   `changes-requested` / “Changes requested on your PR”. `REVIEW_REQUIRED` and
   `APPROVED` mean **Waiting on others**. Missing/unknown overall decisions stay
   unknown; individual reviewer submissions cannot substitute for that decision.
4. For a non-authored, non-draft PR, a complete request list containing an active
   direct user request for the signed-in login means **Needs attention**, with
   typed reason `review-requested` / “Review requested from you”. Login comparison
   is case insensitive. A missing request list stays unknown. A known request
   list without that direct request means **Waiting on others** (no supported
   action identified). Team requests never qualify.

Both reasons have stable identifiers, labels, SF Symbol names, accent emphasis,
and explanations/accessibility labels. Ordinary review work uses no red warning
emphasis. Missing approval and PR age never create an action. Approval never
establishes merge readiness. A comment, unresolved thread, or old notification
never establishes unread state or a reply obligation. There is no durable unread
or acknowledgement signal, so comment reasons are deliberately absent. CI data
does not participate in attention.

## Dashboard and counts

Review / My PRs / Drafts keep their current membership. Actionable PRs are placed
first **within** each tab using a stable partition; equally prioritized PRs keep
existing ordering (discovery update time, then node ID for aggregated ties).
Rows retain identity, author/review context, diff totals, canonical links, keyboard
focus, and click behavior. A compact icon/text label shares the repository line;
its tooltip and the row's VoiceOver label explain the classification and action
reason. Waiting, work in progress, unknown, and previous data use secondary color.
There is no new row, tab, summary screen, urgency banner, or animation.

The menu bar remains a fixed template icon. Its accessible name reports account
presence only: “pingit — Connected” or “pingit — Not connected”. Connected does not
promise that every token is healthy. **There is no menu bar badge or action count.**
`MenuBarIndicatorPresentation` makes this contract testable without PR data.

Existing tab counts still count displayed rows, including retained cached rows;
they are not action totals, unread totals, or a global GitHub inventory. My PRs
excludes drafts; Drafts includes only drafts. Aggregation deduplicates by GitHub
node ID before counting. A section without a result displays “—”. Partial/failed
sections retain known rows and counts with coverage warnings and per-row unknown
or previous labels. An empty incomplete section does not say “All caught up”.

## Partial failures and multi-token behavior

Classification is deliberately conservative at **section granularity**. Any failed,
unvalidated, pending, or interrupted token source withholds action claims across
that section, even when a different token succeeded. Any conflicting metadata in
the merged section also withholds claims across that section, including conflicts
unrelated to an individual PR's review decision. This favors trust over coverage;
future per-row provenance could narrow uncertainty without changing the rules.
Structural token visibility and direct-only scope are informational, since they
cannot prove visibility outside configured repositories; these alone do not
invalidate verified visible rows. Unavailable CI alone also does not gate attention.

Failed refreshes keep the source's previous results and successful timestamp.
Truncated successful refreshes now retain omitted cached rows, tagged by an
in-memory set of node IDs. Newly returned rows in a truncated section remain
unknown, and omitted rows show previous data. A complete successful refresh
reconciles membership and clears retained provenance. Token removal/replacement
continues to remove that source's cache using existing credential boundaries.
Refreshing or cancelling never promotes a previous snapshot to verified current
data. No wall-clock age threshold infers required action or coverage.

The change detector receives **raw** successful discovery results before dashboard
retention. Display-only retained rows are never injected into conversation,
lifecycle, change-detection, or notification inputs. Existing baselines, delivery,
deduplication, and notification preferences remain unchanged.

## Validation

Linux validation: `python3 scripts/validate-static.py` checks Xcode project syntax,
source membership, references, schemes/assets/plists, strict Swift 6 settings,
shell syntax, credential patterns, conflict markers, Markdown links and whitespace.
Native Xcode compilation and tests run only in the GitHub Actions macOS job.
No local macOS build, UI runtime, VoiceOver, or visual verification is claimed.

New deterministic tests cover direct requests, overall changes requested, awaiting
review, approval, drafts, missing/unknown metadata, comments/age neutrality,
partial/failed/stale/cancelled discovery, omitted PR retention/reconciliation,
duplicates and token-order conflicts, classification transitions, stable ordering,
original tabs, reason/accessibility text, menu bar semantics and tab counts. The
full existing discovery, notification, conversation, lifecycle and sync suites
remain in the shared scheme and must pass alongside them. See the Draft PR's
macOS check for the final build/test evidence.

## Manual acceptance checklist (macOS)

- [ ] Run the current build in light and dark mode. Inspect all three tabs with
  long repository names/titles; verify compact rows, truncation help, diff totals,
  ordinary accent emphasis and native contrast.
- [ ] Compare an active direct request and an authored changes-requested PR with
  GitHub. Verify actionable rows appear first, ties stay stable, and PRs remain in
  their original tabs. Confirm approved/awaiting-review PRs say waiting, drafts
  say work in progress, and missing decisions say unknown.
- [ ] Navigate tabs using arrows/⌘1–3, focus rows with the keyboard, activate links,
  refresh with ⌘R, and verify browser destinations and preserved focus behavior.
- [ ] Use VoiceOver to verify full reason explanations, identity, review/diff
  metadata, update time, and menu bar connection-only semantics.
- [ ] Refresh loaded results while offline or with a naturally failing token.
  Verify retained rows/counts, previous-data labels, coverage details, and recovery.
  Inspect naturally partial results without changing permissions to manufacture them.
- [ ] Verify opt-in notifications still deliver existing supported events and
  opening or reordering the dashboard emits no new event.
