# Phase 6A — PR conversations and comment tracking

## Dependency and branch strategy

Inspected `origin/main` at `8211d2d` on 2026-10-22. GitHub reports PR #2
merged at 05:19:48 UTC; native notifications are present on main. This feature
branches directly from that commit in a separate worktree on
`feat/pr-comment-tracking`. No stacking, cherry-picking, changes to PR #2, or CI
infrastructure changes are needed. The original checkout remains on main.

## Design constraints

Extend the existing dashboard refresh, detector actor, atomic snapshot and native
notification coordinator. No extra timer, activity feed, team discovery or unread
counts. Fail closed on incomplete conversation coverage. Preserve Phase 5B state
while migrating its version-1 snapshot to version 2.

GitHub sources inspected before implementation:

- [GraphQL pull request fields](https://docs.github.com/en/graphql/reference/pulls)
- [GraphQL authentication](https://docs.github.com/en/graphql/guides/forming-calls-with-graphql)
- [Issue comment permissions](https://docs.github.com/en/rest/issues/comments)
- [Review comment permissions](https://docs.github.com/en/rest/pulls/comments)
- [GraphQL rate and query limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)

Pull requests: Read-only covers review comments and is an accepted permission for
issue comments on PRs; Metadata: Read-only remains required for repository access.
No write, organization Members, or team permissions are added. Actual selected
repository visibility and organization approval cannot be inferred from an empty
search or from the token's owner label. GraphQL field denial is handled as failure,
not as an empty comment connection. No credential values were inspected.

Implementation and validation details follow in subsequent commits.

## Implementation and event types

`GitHubConversationDiscovery` performs optional conversation work inside the existing
per-token dashboard workers, after authored/requested discovery. No second timer or
notification polling loop exists. The same `GitHubClient` instance supplies the
transport's credential-isolated rate gate. At most two token workers run; each has
one conversation request in flight after its two existing section requests drain.
PR section results remain usable if comment permissions or transport fail.

`PullRequestChangeEvent.Kind` adds `newPRComment`, `newInlineReviewComment` and
`newReviewThreadReply`. Authoritative `replyTo` distinguishes a reply from an inline
root; thread and submitted-review IDs accompany events when available. Review
submissions and review bodies are not treated as issue comments. A textless approval
continues through the existing review detector.

Eligibility comes only from complete, fresh authored/direct-request searches. Each
token monitors at most 40 PRs, prioritizing authored, then currently requested, then
retained requests, with stable node-ID ordering. Previously requested PRs retain
conversation coverage for seven days after their last verified direct request,
including across restart. Each retained PR is verified directly by node ID and
must still be OPEN. An explicitly CLOSED/MERGED node retires conversation metadata.
Missing nodes do not imply closure. This does not enumerate repository PRs or teams.

## API/query strategy and cost

For N selected PRs, each synchronization adds `ceil(N / 5)` lightweight batched
`nodes(ids:)` probes, plus at most one detail request per changed batch. With no
tracked PRs there are zero conversation API requests. At the 40-PR cap, unchanged
coverage costs eight probes per token; initial/fully changed coverage costs at most
16 requests per token, in addition to existing discovery. Under the default five
minute interval, unchanged maximum coverage adds 96 probes per hour per token.
Actual GitHub point costs depend on connection fan-out; request counts are not point
counts. `rateLimit.remaining/resetAt` is checked before more work, reserving 50
points for other work. Existing HTTP primary/secondary limits and Retry-After gate
future calls per credential. A rate interruption stops further batches without
manufacturing coverage for unfetched PRs and feeds the existing shared scheduler's
backoff. There is no immediate retry or catch-up loop.

A probe reads PR identity/state/update time, the issue-comment count and tail ID,
plus at most 50 thread IDs with their comment counts and tail IDs/publication times.
It fetches no body. The hashed fingerprint is independent of thread encounter order.
An unchanged complete probe can advance verification without loading bodies. A
changed fingerprint only triggers retrieval; it never constitutes a comment event.
Details batch up to five PRs with at most 50 issue comments, 50 threads per PR and
50 comments per thread. Every connection must fit that single page; totalCount,
node count, nullability and hasNextPage must agree. This bounded pagination policy
never follows an unbounded historical chain. The worst detail query has about
12,805 returned PR/repository/thread/comment nodes, below GitHub's 500,000-node
limit. There is no per-comment or per-thread request fan-out.

The selected comment/thread connections expose cursor pagination, without a `since`
filter. Timeline's `since` cannot establish complete existing-thread replies.
Consequently this phase uses bounded complete details on change, rather than a
saved tail cursor that could miss context or deleted/reordered nodes. Long PRs or
threads beyond these limits intentionally do not notify, even when a tail comment
is visible. The tracking cap and API/coverage failures appear in the existing
coverage details. No dashboard tab, history view or unread count is added.

## Confidence, relevance and failure handling

A new event requires a previously established comparable baseline, an unseen stable
comment ID, and a GitHub `publishedAt` strictly newer than the previous verification
floor and no later than the current observation. `createdAt` is also validated;
publication time handles inline drafts submitted later. The last complete request's
start time supplies the floor, avoiding advancing it past a comment created while
the request was in flight. Old IDs remain consumed across edits, deletions and
reappearance; newly accessible older publications are quiet. Equal timestamps and
local clock regressions are handled conservatively. Unknown/deleted authors and
pending review comments never generate notifications.

Self filtering uses GitHub actor IDs, with case-insensitive login fallback. Authored
PRs accept other actors' comments. Requested/retained-review PRs require prior viewer
participation in the specific fully fetched thread (or PR conversation for issue
comments), or an explicit bounded-login mention. Future participation does not make
earlier comments relevant. Quoted/code/HTML mention lines are conservatively ignored;
this heuristic can miss valid Markdown mentions. Bodies exist temporarily only for
normalization/mention checks. `Bot` actor type identifies automation; a login suffix
alone does not. Bot comments are off by default, with an optional preference.

Each token/PR result has explicit coverage. Only completed current-flight results
enter detection; cached dashboard rows cannot verify a comment. Failure, truncation,
missing nodes, conflicting search metadata or absent contributor results retain
trustworthy IDs/timestamps and break comparability. The next complete observation
quietly rebaselines; comments across these gaps may be deliberately missed. Complete
independent batches can still progress. Every contributing token must agree on the
current fingerprint and comment evidence for a shared event; unioned IDs deduplicate
the event. Token add/remove/replacement conservatively breaks all comment baselines,
including scopes without a successful result yet. Existing review history is retained.
Scope changes and failures never produce synthetic comment deletions or notifications.

The detector still performs compare -> atomic snapshot commit -> callback. A failed
write emits nothing and preserves the previous state for retry. Sleep, shutdown and
credential/session changes invalidate pending asynchronous work. Events have no
replay queue or activity history. Delivery remains best effort and at most once;
a crash after commit can lose a notification. Opaque GitHub IDs cannot prove whether
an invisible comment was deleted; no deletion event is modeled.

## Privacy, storage and migration

The existing mode-0600 atomic snapshot in its mode-0700 Application Support directory
is now schema version 2. Version-1 decoding preserves account identity, epoch,
revision, all PR/reviewer state and repository coverage barriers. Missing optional
conversation fields mean a quiet first baseline; the migrated version is written
on the next changed commit. Corrupt/future snapshots still rebaseline safely.

New persisted values are credential-reference topology, PR/repository node IDs and
PR number, a SHA-256 probe fingerprint, verification/last-direct-request timestamps,
comparability, consumed comment IDs and associated submitted-review IDs needed to
suppress delayed duplicate review signals. No bodies, titles, repository names,
URLs, actor logins, tokens, responses or conversation history are persisted. Thread
IDs appear only in memory and inside a digest. IDs and timing remain sensitive local
metadata; hashing does not make them anonymous.

Storage remains bounded by eight MiB, 64 scopes and 20,000 existing source-section
PR entries. Conversations add at most 40 PRs per source, 3,000 consumed comment IDs
and 3,000 associated review IDs per PR, with a global 100,000 comment-ID limit. These
bounds fail closed, never silently evict deduplication metadata. Scopes are pruned
on removal/disconnect. Expired retention is pruned only with complete fresh eligibility
searches. Verification metadata may cause one atomic write per successful sync.

## Native notifications and preferences

The existing master enablement, system authorization, bounded queue, sound and
lifecycle cancellation remain authoritative. Settings adds PR/inline comments and
thread replies (on when master is enabled), and automated bot comments (off). Master
notifications remain off by default. No automatic permission prompts are introduced.

Comment content is concise: `@reviewer commented on #1.` or
`@reviewer replied to a discussion on #1.` Repository context remains in the existing
subtitle. Comment bodies and PR titles are not copied into these new messages.
Destinations are revalidated during normalization, message construction and activation:
only canonical HTTPS github.com PR paths with positive numeric `issuecomment-` or
`discussion_r` anchors are allowed; `/files#discussion_r…` is accepted too. Credentials,
ports, queries, encoded paths/anchors, arbitrary fragments and mismatched PR metadata
are rejected. Canonical URLs outside these known shapes are suppressed.

For the same submitted review, an enabled valid approval/change-request notification
absorbs its root inline-comment notifications in the same batch using authoritative
review IDs. Replies remain independent. Persisted associated review IDs also suppress
a delayed review decision after its relevant inline comments were consumed, including
across restart. Baseline consumption is independent of notification preferences;
as with existing events, changing preferences does not replay earlier activity.
A matching review ID is required: missing/incomplete review metadata cannot prove
that two signals belong to one submission.

## Tests and validation

Deterministic fixtures cover first baseline, new issue/inline/reply events, edits,
deletions/inaccessibility, old newly visible comments, self identity, bot actor types,
requested-review participation/mentions, multiple comments/out-of-order timestamps,
token deduplication/addition/removal/replacement, failed commits, restart, version-1
migration/privacy, retention/bounds, unchanged probes, pagination truncation, primary
budget interruption and secondary limits. Integration fixtures exercise the existing
refresh flight, coalescing, independent comment errors and late cancelled responses.
Notification tests cover preferences, specific-comment activation, malicious URLs,
and review/comment deduplication. All original test cases remain in the shared scheme.

Linux: `python3 scripts/validate-static.py` passes project syntax, references and
source membership, plist/entitlement/scheme/assets, credential-pattern/conflict-marker
scans, Markdown links, strict Swift settings, shell syntax and `git diff --check`.
Linux has no Swift/Xcode toolchain here. These checks are not compilation or tests.

macOS CI: existing workflow on Draft PR #3 uses macOS 15 arm64, Xcode 26.3, Swift 6,
complete concurrency and warnings as errors. The initial run found a recursive
nested Swift Testing `#require` macro in the new migration fixture; it was corrected.
The second run compiled the app and tests and executed 308 tests; one new privacy
assertion incorrectly matched the existing `reviewers` JSON key instead of an actor
value. The assertion was corrected to check the quoted actor value. The final implementation run passed **311 tests across 30 suites** and built the
app successfully at `ef13e3b`:
[macOS CI run 39728988515](https://github.com/birosrichard/pingit/actions/runs/39728988515).
The only framework-tool notices were the existing AppIntents metadata-extraction
warnings, not Swift compiler warnings. The following documentation-only commit
records that result; current-head CI is also visible in the Draft PR checks. No CI infrastructure was changed.
Native notification delivery, production signing/Keychain entitlements, real PAT
coverage and live runtime behavior require manual acceptance on macOS.

## Known limits and manual acceptance

Search is eventually consistent and GitHub connections are not transactional. A
comment created and deleted entirely between polls is unobservable. Timestamp/skew,
coverage barriers and bounds favor missed alerts over historical replay. Silent
permission changes within an unchanged credential cannot be detected perfectly;
old publication timestamps and complete contributor evidence mitigate replay, but
GitHub does not expose a visibility-generation marker. This is not an exhaustive
conversation client. There is no macOS live notification acceptance claim.

- [ ] Launch a development-signed build with the normal sandbox and Keychain identity.
- [ ] Upgrade a Phase 5B/5C snapshot; confirm existing review detection survives and
      historical comments remain quiet. Restart with the same tokens and repeat.
- [ ] Enable master notifications and explicitly authorize macOS delivery; confirm
      denied/global-off/type-off settings suppress new alerts without catch-up.
- [ ] On an authored PR, receive issue comments, root inline comments and replies
      from another user; verify concise text and the exact clicked discussion.
- [ ] Verify own comments are quiet; verify a GitHub Bot is quiet by default and
      can be included explicitly. Check bot-like names are not suffix-classified.
- [ ] On a directly requested PR, verify unrelated conversation is quiet while a
      mention or a reply in the user's participated thread alerts. Fulfill the
      request and verify the bounded seven-day retained coverage.
- [ ] Submit approval with a body and inline comments; verify no duplicate review
      alert for that submission. Check independent replies still alert.
- [ ] With overlapping tokens, verify one alert; add/replace/remove a token and
      confirm no historical replay. Check partial/offline failures preserve PR rows
      and show conversation coverage warnings; recovery rebaselines quietly.
- [ ] Check long/truncated conversations fail closed, no extra tab/count/feed appears,
      and the dashboard remains responsive with background sync and sleep/wake.
