# CI and pull request diff metadata — Phase 4A

## Independent meanings

**Checks passed is not Ready to merge.** `GitHubCheckSnapshot` describes only CI
observed for a validated PR head. `reviewStatus` remains GitHub's independent review
decision. Reviews, conflicts, rulesets, branch protection, merge queues and other
requirements can still block merging. This phase does not retrieve or calculate
merge readiness and never changes review semantics. Row help and VoiceOver state
this distinction explicitly, including when CI succeeds.

## API and bounds

Both existing search queries add PR-level `changedFiles`, `additions`, `deletions`,
`headRefOid`, and `commits(last: 1) { nodes { commit { oid statusCheckRollup { ... } } } }`.
The commit OID must equal `headRefOid`; missing or disagreeing commits are unknown.
There is no lookup through a repository branch, no patch/file download and no
REST request per PR.

The rollup requests `state` and `contexts(first: 1)` with only these connection-wide
counters: `totalCount`, `checkRunCount`, `statusContextCount`,
`checkRunCountsByState { state count }`, `statusContextCountsByState { state count }`.
These include CheckRun and legacy StatusContext results, regardless of CI provider.
No context nodes, edges, suites or individual runs are fetched in production.
`first: 1` bounds the connection but does not truncate connection-wide counters.
There is consequently no check-list pagination and no N+1 request pattern.

Field support was checked against GitHub's [PR schema](https://docs.github.com/en/graphql/reference/pulls#pullrequest),
[commit/rollup schema](https://docs.github.com/en/graphql/reference/commits#statuscheckrollup),
[counter schema](https://docs.github.com/en/graphql/reference/commits#statuscheckrollupcontextconnection),
and [check-state enums](https://docs.github.com/en/graphql/reference/checks#checkrunstate),
then exercised with live read-only GraphQL responses on 2026-10-21.

Existing search limits remain: 50 PRs/page, default 200 results/section, 20 pages,
1,000 scanned hits. At most two token workers run, each with two section searches.
The query adds one commit per PR and fixed state buckets; it adds no requests or
unbounded nested lists. Reviews retain their existing bounds.

## CI normalization

Counters must be nonnegative, bounded GraphQL integers, have unique state buckets,
sum to their check/status totals, and agree with `totalCount`. Missing arrays,
unsupported positive-count states, duplicate buckets or mismatched totals mark
incomplete details. Zero-count future buckets provide no result evidence.

Resolution order:

1. A real FAILURE, ERROR (legacy), TIMED_OUT, STARTUP_FAILURE or ACTION_REQUIRED
   wins over successes and pending results. Exact failure counts require complete,
   consistent counters and an appropriate aggregate state.
2. Pending/expected/queued/in-progress/waiting evidence prevents success. An
   authoritative FAILURE/ERROR still wins over pending counters, without an exact
   failure count when the counters disagree.
3. Complete cancelled results yield Cancelled; cancellation alone is not a genuine
   failure, even if GitHub's aggregate is FAILURE.
4. Without sufficient counters, GitHub FAILURE/ERROR or PENDING/EXPECTED supplies
   a conservative failure/running fallback. SUCCESS alone cannot prove success.
5. A complete empty connection yields No checks. A null/missing rollup yields
   Unknown/unavailable, since absence cannot establish CI access.
6. Complete skipped/neutral results, including mixtures with successful results,
   yield Skipped/neutral. They never imply all required checks passed.
7. Passing requires complete known counters, exclusively successful results and
   GitHub SUCCESS. Unsupported aggregate states cannot establish success.

STALE and COMPLETED without a conclusion remain incomplete, rather than successful.
No required-check policy engine or effective branch-protection vote ledger exists.

A failed optional CI field must not remove the PR. Only GraphQL errors whose paths
are confined to `search.nodes[index].commits` can recover: that entire CI subtree
is discarded before typed decoding, while PR/review/diff metadata survives. The
connection exists exclusively for CI. Every affected row becomes unavailable and
its source carries a CI coverage limitation. Unpathed/unrelated errors, missing PR
nodes, HTTP access failures and rate limits still fail the source independently.
Server error messages and credentials are never displayed. No retry is added.

## Multi-token reconciliation

PR identity remains the node ID. Metadata reconciliation considers all observations
at the newest PR `updatedAt`, preserving existing review/request merge behavior.
Older observations never fill newer CI or diff values, even for the same head.

- Equal-time different head SHAs: withhold CI and diff metadata, clear the ambiguous
  head and warn. A third agreeing token cannot erase this conflict.
- Equal-time same head: validated available CI can replace unavailable or mismatched
  CI from a token with less access. Unknown/incomplete evidence is not equivalent
  to mere unavailability and cannot silently become success.
- Identical available snapshots retain their precision. Conflicting available
  snapshots retain real failure first, then pending evidence; otherwise they are
  unknown. Exact counts are withheld and coverage warns, independent of token order.
- CI `updatedAt` is not inferred from PR `updatedAt`. Concurrent check transitions
  may therefore conservatively conflict until the next existing refresh.
- Compatible diff totals fill missing totals only within the newest snapshot.
  Contradictory totals are unavailable with a warning, independently of CI.

Original per-token results, access limitations and errors remain available. A denied
CI source cannot turn its failure into passing. A successful source does not prove
that every private repository or check provider is visible.

## Compact rows and refresh

Review/author metadata retains its place. One compact line adds, for example,
`3 files  +142  −28 · Checks passed`, with native green/red additions/deletions,
neutral file count, distinct CI icons and semantic CI colors. Larger values use
English compact formatting (`1.2K`, `1.5M`); singular/plural file labels remain
correct. Help and VoiceOver read full integers. Missing/invalid totals show Diff
unavailable and never fabricated zeroes. Zero values are displayed when provided.
All three inboxes use the same row component. Width fallback places diff and CI
on separate lines, with existing title/repository truncation and keyboard Link
activation. No new screen or decorative card is introduced.

The existing in-memory refresh lifecycle covers all fields: 60-second freshness on
opening, manual Refresh, retained rows, duplicate prevention, per-token failures,
cancellation and generation guards. Retained CI is explicitly labelled Previous
and uses neutral color during refresh/failure. A new-head response replaces the
old snapshot even when new CI is unavailable. No background polling, notifications,
private CI persistence or GitHub writes are introduced.

## Token permissions and current GitHub limitations

- PR metadata and diff totals: Pull requests **Read**, plus automatic Metadata
  **Read**, for the selected repositories.
- Legacy statuses: Commit statuses **Read**. GitHub documents this for the
  [status read API](https://docs.github.com/en/rest/commits/statuses#list-commit-statuses-for-a-reference).
- Checks: the [check-run read API](https://docs.github.com/en/rest/checks/runs#get-a-check-run)
  documents Checks **Read**. It also lists fine-grained PATs as supported.

However, GitHub's [PAT limitations](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#fine-grained-personal-access-tokens-limitations)
still explicitly list calling the Checks API as unsupported for fine-grained PATs.
The documentation is inconsistent. Do not promise an editable Checks permission
or complete check visibility for existing PATs. Public results or a successful
`/user` request do not validate private Checks access. No write scopes, classic
PAT migration, Contents scope, OAuth or GitHub App authentication are requested.

For each personal/organization token separately: open GitHub Settings → Developer
settings → Personal access tokens → Fine-grained tokens; verify its resource owner
and selected repositories, retain Pull requests Read, and add Commit statuses Read
if needed. If Checks Read is actually offered for that credential, choose only Read;
if unavailable or denied, keep using PR/diff metadata with Checks unavailable.
Organization permission changes may require renewed administrator approval. If a
new token is needed, replace only that connection in pingit Settings using its
secure input, then Refresh; existing connection identity and other tokens survive.
Never copy a token into a shell, log, fixture or bug report. See [validation and
manual acceptance](phase-4a.md) for what has actually been exercised.
