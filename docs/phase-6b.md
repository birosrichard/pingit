# Phase 6B — Pull request lifecycle tracking

## Branch and architecture

This phase starts directly at `origin/feat/pr-comment-tracking` commit
`59d1423a4c565c286cbc29f891a2804a1b52fcb5` in the new isolated
`pingit-phase6b` worktree. Branch: `feat/pr-lifecycle-tracking`. The Draft PR
must target `feat/pr-comment-tracking` while Draft PR #3 remains unmerged.
The Phase 6A checkout and PR are unchanged. Nothing is merged or retargeted.

Read the prior phase reports and inspected PR models, search normalization,
credential aggregation, coverage metadata, detector, snapshot store, native
notifications, preferences, scheduler, tests and CI before implementation.
The extension adds a dedicated authoritative lifecycle value, a bounded node lookup,
and a pure projection inside the existing detector actor. It does not rewrite
search, review or comment detection. Draft → Ready remains in the existing detector;
Ready → Draft is deliberately omitted. Review / My PRs / Drafts remain unchanged.
Terminal lookup values never enter the open dashboard result collection.

GitHub schema references checked during development:
[PR fields](https://docs.github.com/en/graphql/reference/pulls#pullrequest) and
[GraphQL rate/query limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api).
The query reads `state`, `isDraft`, `updatedAt`, `closedAt`, `mergedAt`, stable ID,
author, canonical URL, repository context, viewer identity and remaining quota.
No lifecycle claim comes from search disappearance, approvals, checks or branches.

## Eligibility, API budget and retention

Only already observed authored PRs are eligible. Requested-review PRs do not
receive lifecycle notifications. Complete fresh authored searches admit candidates;
on upgrade only, existing authored snapshot entries can also seed a quiet direct
baseline. Initial terminal observations never alert. Each direct batch verifies
the credential's viewer identity and the PR's author, identity, URL and timestamps.

There are at most **100 lifecycle records globally**. Each sync issues at most
**five additional GraphQL requests**, each `nodes(ids:)` query containing at most
**20 unique PR IDs**. This is a global budget across all tokens, independent of
Phase 6A conversation requests. A PR is assigned to exactly one known contributing
credential; there are no duplicate cross-token lookups or same-flight failover
retries. With one overlapping credential group the cost is `ceil(N / 20)`, at most
five requests; fragmented credentials may leave budget unused within batches.
No eligible targets means zero requests. The query has no paginated connections,
comment bodies, reviews, history or repository scans. Request limits are not a
promise about GitHub point accounting; returned quota and the existing transport
primary/secondary rate gate remain authoritative. At the default five-minute
interval the maximum is 60 additional lifecycle requests per hour globally.

Batches run sequentially after the existing bounded source workers, inside the
same refresh flight and 120-second watchdog. Manual, automatic and on-open refresh
share this path. Errors stop later lifecycle batches for that credential; no retry
loop or timer is added. A result with fewer than 50 remaining points preserves its
verified nodes, stops that token's later work, and supplies its reset deadline to
the existing scheduler. Transport restrictions also protect later requests.

Verified open PRs stay tracked while access continues. Unverified/open/pending
records expire after **30 days without successful direct verification**. Closed
PRs are checked for reopening for **seven days from first terminal observation**;
unchanged polls do not extend this deadline. Reopening clears terminal retention.
Merged PRs stop polling immediately and retain only a seven-day deduplication
record. Expired records are removed, and first discovery after eviction baselines
quietly. Records are never evicted to make room for newer ones before retention;
capacity gaps appear in existing discovery coverage details. Oldest verification
is prioritized for batching; exceeding the batch budget can suppress alerts.

## Confidence and transition events

Typed events are `prMerged`, `prClosed` (without merge), and `prReopened`.
An event needs two comparable direct observations with stable repository/PR
identity, monotonic source timestamps and a new authoritative state. Merge/close
timestamps must be newer than the prior verification floor and no later than the
current receipt. Reopening uses CLOSED → OPEN plus a newer `updatedAt`; it does
not claim who reopened the PR or reconstruct intermediate history.

All known contributing authored searches must be complete and fresh in the same
flight. Search pagination limits, conflicting metadata, a skipped contributor,
missing/null node, visibility loss, token failure and unverified results preserve
trustworthy state and break comparability. Recovery is a quiet baseline. Independent
verified nodes can progress even if other nodes are null. Credential addition,
removal or replacement rebases lifecycle comparability, including across restarts.
An identity change discards the other account's baseline. An inaccessible selected
credential is not retried via another token in that flight; this favors missed alerts
over uncertain visibility transitions. Cached dashboard rows never verify state.

The existing generation/session, increasing sequence, cancellation and sleep/shutdown
checks reject stale responses before commit and again before delivery. Atomic save
failure retains the old baseline and delivers nothing; a later successful attempt
can detect the transition. Stable event identities hash account/epoch/PR/kind and
the transition timestamp. Committed state deduplicates across tokens and restarts.
Notifications remain best effort and at most once: a crash after commit or a native
delivery failure can lose a banner. There is no replay queue or persistent history.

## Snapshot migration and privacy

The additive storage change uses **schema version 3**. Version-1 and version-2
snapshots decode with absent lifecycle fields, preserving identity, epoch, revision,
review history, comment IDs, associated review IDs and source coverage barriers.
The next committed snapshot writes v3 using the existing private atomic store:
mode-0700 directory, mode-0600 temporary file, synchronization and atomic rename.
Future/corrupt versions quietly rebaseline as before.

New fields contain a bounded global dictionary of PR node ID → repository node ID,
PR number, optional authoritative state (nil while awaiting baseline), draft flag,
update/verification/terminal-observation times, credential storage references and
comparability, plus the active credential topology. No titles, repository names,
URLs, bodies, actor logins, tokens, responses or event lists are persisted.
The existing eight-MiB/64-source/20,000-section-entry and comment bounds remain;
lifecycle validation adds a strict global 100-record bound. These IDs and timestamps
are sensitive local metadata, not anonymous data.

## Native notifications

The master switch remains off by default. With master notifications enabled,
**Your PR merged** defaults on; **closed without merging** and **reopened** default
off. Three compact Settings switches reuse boolean UserDefaults preferences and
the existing native service, authorization, bounded queue, sound and cancellation.
Messages say “Your PR #1 was merged/closed without merging/reopened.” Repository
context stays in the existing subtitle; PR titles are not included in lifecycle
messages. Canonical HTTPS GitHub PR URLs are revalidated for construction and
activation using existing navigation safeguards. Changing preferences does not
replay previously consumed events. Native delivery failure has no retry replay.

## Validation

Linux: `python3 scripts/validate-static.py` passes project parsing/references/source
membership, plist/entitlement/scheme/assets, credential/conflict scans, Markdown
links, strict Swift settings, shell syntax and diff whitespace. No local Swift or
Xcode toolchain is available. These checks do not compile the app or run tests.

Added deterministic lifecycle detector, transport, refresh and native-notification
fixtures covering terminal/reopen transitions, first terminal baselines,
disappearance, gaps, token topology/failure, cross-account inputs, pagination and
conflicts, stale/cancelled responses, migration, preserved review/comment state,
restart deduplication, failed atomic commits, storage/query/retention limits,
notification preferences, URL activation and delivery failure. Existing Phase 5B
and Phase 6A tests remain in the shared scheme. macOS CI retains Xcode 26.3,
Swift 6, complete concurrency and warnings as errors. Its existing PR base filter
also includes `feat/pr-comment-tracking` for this stacked Draft PR.

macOS CI passed at implementation commit `a5ed4442d71db491df17771c78589b22d65bb31f`:
[macOS CI run 39739443655](https://github.com/birosrichard/pingit/actions/runs/39739443655).
The application built and **339 tests across 34 suites passed**, including the
existing Phase 5B and Phase 6A suites. The runner used macOS 15 arm64, Xcode 26.3
(build 17C529), and the Swift 6.2.4 compiler in Swift 6 language mode. Logs confirm
`SWIFT_STRICT_CONCURRENCY=complete`, Swift warnings as errors, and C-family warnings
as errors. The only tool warnings were the existing AppIntents metadata-extraction
notices; no Swift compiler warnings were accepted. Earlier runs found test-fixture
name shadowing and overlapping dictionary access; both were corrected on this branch
without weakening compiler settings or test assertions.

This documentation-only follow-up records the passing implementation run; the PR
checks show validation for the latest head. Linux static checks and workflow YAML
validation also pass. Native banner delivery and development-signed runtime behavior
have not been manually verified.

## Known limitations and manual acceptance

Polling observes current state, not every intermediate transition. A close/reopen
cycle entirely between polls cannot be reconstructed. State changes across coverage
gaps, after retention, or beyond caps may be missed intentionally. GitHub search is
eventually consistent; direct-node authority is required for all lifecycle alerts.
Within-credential permission changes have no explicit GitHub visibility generation;
missing nodes and timestamp/coverage barriers suppress uncertain events.
Reopening after seven days is outside retained coverage unless independently
rediscovered, in which case it is quiet. Ready → Draft is not implemented.
No real PAT, native notification banner, signed launch, physical sleep/wake,
Intel/Release build or UI/VoiceOver acceptance is claimed from Linux development.

- [ ] Upgrade a Phase 6A snapshot; verify reviews and comment deduplication survive,
      historical PRs remain quiet, and restart causes no replay.
- [ ] Enable notifications and explicitly authorize macOS delivery. Merge an authored
      tracked PR; verify one concise native alert and correct GitHub activation.
- [ ] Enable closure/reopen types, close an authored PR without merging, reopen within
      seven days, and verify one alert per observed transition across restart.
- [ ] Keep both optional types off and confirm they remain quiet; disable the master
      and check all lifecycle banners stop without later catch-up.
- [ ] With overlapping tokens, verify one notification; add/replace/remove tokens,
      revoke repository access, and recover without historical replay.
- [ ] Exercise manual/background refresh, sleep during an in-flight lookup and wake;
      verify no stale alerts, no extra timer and no overlapping refresh.
- [ ] Confirm merged/closed PRs leave the open lists, three tabs remain, direct review
      requests stay quiet for lifecycle events, and Draft → Ready still works once.
- [ ] Receive issue/inline/reply comments and approvals/change requests; verify Phase 6A
      and Phase 5B behavior, self/bot filters and delayed review deduplication.
