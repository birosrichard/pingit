# Phase 5B — Reliable pull request change detection

Implemented on 2026-10-21 (Europe/Prague). This phase detects internal events from
completed existing discovery results. It adds no API queries, notifications,
permissions, activity UI, telemetry, GitHub writes or persistent event history.

## Architecture and delivery

The shared `PullRequestDashboard.refresh` flight collects **only freshly received**
per-connection section results. After its bounded workers drain, it cancels the
network watchdog and awaits `PullRequestChangeDetector`. The flight stays occupied
through comparison and commit, so manual, popover and automatic triggers continue
to coalesce. Cached dashboard results never masquerade as successful discovery.
The Phase 5A scheduler, transport, normalization and dashboard layout are reused.

The detector is an actor. Loading, comparisons, encoding and filesystem operations
run outside the main actor, without suspension between comparison and commit.
Connection generations reject obsolete configurations, and increasing refresh
sequence numbers reject out-of-order/repeated inputs. Source PR timestamps never
move backward. Existing session and cancellation checks run before processing and
again before event delivery. Sleep, shutdown, removal and replacement invalidate
the same refresh flight; cancelled workers still drain before another flight starts.

`dashboard.onChanges` is a single replaceable main-actor callback receiving one
committed batch. It has no subscribers list, replay buffer, queue, retained last
batch or history. With no consumer, events are discarded after baseline advancement.
Future Phase 5D code can install this callback. `changeDetectionStorageFailed`
exposes a fixed internal failure flag without raw errors or private snapshot data.
Mocked connection initializers keep persistence disabled unless explicitly injected.

## Minimal snapshot storage

One version-1 Codable JSON document lives at:

```
<Application Support>/dev.biros.pingit/ChangeDetection/snapshot.json
```

The signed sandboxed app resolves Application Support inside its app container.
Snapshots contain a hashed account identity, a random baseline epoch, a monotonic
revision, independent credential-reference scopes, repository and PR node IDs,
PR numbers/update timestamps, draft/decision state, hashed case-normalized reviewer
identities with latest review node IDs/states, reviewer comparability flags, and
repository rebaseline barriers after scope removal. Section absence means no valid
baseline; a known empty dictionary is distinct from absence.

**No PAT, PR title, repository name, URL, author/reviewer login, body, comment, diff,
file, transport envelope or event history is stored.** The epoch distinguishes real
future transitions after a corrupt/incompatible baseline reset. IDs, numbers and
state still reveal some private activity locally; hashes are pseudonyms rather
than encryption. Credentials remain exclusively in the existing Keychain store.
Nothing is logged or sent to another service by this feature.

Writes create a mode-0600 temporary file in a mode-0700 directory, synchronize and
close it, then atomically rename it over the previous snapshot. Normal failures
remove the temporary file. UUID-named interrupted temporary writes are cleaned on
load/next write. Identical semantic snapshots cause no write, even if observation
time or pagination ordering changes. Time is carried on emitted events rather
than rewriting a last-poll timestamp on every sync.

There are hard limits of **8 MiB**, **64 source scopes**, **20,000 source-section PR
entries** and **50 reviewers per PR**. Oversized input files fail closed rather than
being overwritten. Invalid/corrupt/unsupported-schema JSON starts a quiet fresh
baseline and is replaced only after a successful commit. Ordinary read/write errors
preserve the baseline and suppress delivery. Exceeding write bounds also preserves
the previous baseline and reports storage failure; it never silently evicts state.
Removal/disconnect prunes the corresponding private identifiers. There is no schema
migration yet: incompatible formats safely rebaseline. The design assumes the
application's single detector, with no cross-process writer coordination.

## Events and confidence rules

Every event carries a stable ID, kind, PR node ID, current repository identity,
PR number, optional current title, canonical GitHub URL, observed time, optional
reliably identified reviewer, signal origin, previous/current state and source IDs.
Titles are available only in memory. A removal after restart may lack a title;
its repository and canonical PR URL come from current repository-access evidence.
Review decisions never imply merge readiness.

All detection requires complete, untruncated section discovery, including nested
review-request coverage. Explicit conflicting-result coverage also withholds a
section. Token-visibility/direct-only limitations remain structural: success is
never interpreted as GitHub-wide coverage. Partial success can advance a healthy
section while preserving every failed/truncated section's trustworthy state.

| Event | Evidence required |
| --- | --- |
| Review requested | Absent from the prior union of active direct requests, present now; the same repository was already observed through exactly the same source scopes; every relevant scope has prior request coverage and complete fresh request results. Newly visible repositories establish baselines. |
| Review request removed | Previously active, absent from the current union, plus the conditions above. Each contributing source must still show that repository in a complete current authored/requested result. If the repository disappears entirely, retain the old request and suppress removal. |
| Approved / changes requested, overall | Same previously known authored PR and contributing credential scopes, all freshly and completely fetched; strictly newer PR update timestamp; previous and current authoritative decisions each agree across tokens. Known decisions may transition to approved/changes requested, independent of individual-detail completeness. |
| Approved / changes requested, reviewer | Both latest-review sets are complete, identifiable, and agree across tokens; overall observations also agree; the PR update timestamp increases; a new review node changes an identifiable reviewer's state to approved/changes requested, or adds that reviewer to a previously complete set. |
| Ready for review | Previously known authored draft becomes ready, with the same fresh complete sources, agreeing draft states and a strictly newer update timestamp. First-discovered ready PRs and ready-to-draft changes are quiet. |

Unknown/null overall decisions are never treated as no reviews. Unknown-to-known
alone is suppressed. A comparable new individual review can still emit the
corresponding reviewer event during such a transition. Dismissed, pending, unknown,
and superseded reviews do not supply review events. A previously dismissed review
is not interpreted as a new approval on reappearance. Existing bot approvals are
ordinary baseline state; genuinely new identifiable bot reviews use the same rules.
No review-history reconstruction is performed.

Incomplete reviewer details retain the last trustworthy reviewer values with an
explicit comparability barrier. The next complete observation quietly rebaselines
review details. A known overall decision can be compared separately. Conflicting
token decisions suppress both overall and individual review signals; incompatible
review lists cannot be combined into an individual signal. An overall event absorbs
same-kind reviewer changes in that observation, preventing duplicate signals for
one action. Distinct simultaneous reviewer opinions can produce distinct events.

## Multi-token and partial-failure safety

PR node IDs deduplicate membership across tokens. Reviewers use existing latest
non-pending normalization, case-insensitive identity keys and latest review node IDs.
The detector never unions incompatible reviewer lists to manufacture completeness.
All contributing scopes for an authored transition must be fresh in the same flight;
a later refresh of a previously stale token cannot repeat the transition.

Scopes use the existing credential storage reference, an independent UUID rather
than a token value/digest. Replacement changes this reference. Added/replaced scopes
establish quiet baselines. Removed scopes are pruned; affected repositories get a
persisted rebaseline barrier until a complete current observation reconciles them.
This suppresses topology-induced changes without resetting unrelated repositories.
An account identity change resets its state; mixed account input is rejected.

A successful empty search cannot prove retained repository access. Both authored
and requested state are retained for repositories with no current visibility
witness, including across restart. Failed/truncated sections retain all previous
state. An actual complete absence within a repository still visible to that source
can retire that section entry. No disappearance event for authored PRs is modeled.

## Commit and deduplication guarantees

Order is **compare → atomic snapshot commit → in-memory advancement → session check
→ callback**. Stable SHA-256 event IDs incorporate account/baseline epoch, committed
revision, PR node ID, kind and reviewer identity when applicable. Equivalent inputs
from the same baseline yield the same IDs regardless of pagination/token ordering
or observation time. Distinct later transitions receive new revisions.

A failed save emits nothing and leaves in-memory baseline state unchanged. Retrying
can safely commit/deliver the event once. Restart reads the already committed state,
so identical refreshes, immediate manual-after-background refresh and two-token
copies never replay it. Source reconciliation persists before removing its baseline.

Delivery is **at most once**, not a durable outbox: a crash, cancellation or identity
change after commit but before callback can consume an event without delivery.
Cancellation during I/O finishes an already-started atomic commit but withholds the
batch; the next refresh/restart cannot replay it. No event can be emitted before a
successful commit. Power-loss durability beyond filesystem rename semantics and
exactly-once consumer side effects are not promised.

## Validation

- **248 tests in 21 suites pass**, preserving the previous 217 tests and adding 31
  detector/storage/integration tests. Parameterized cases exercise additional inputs.
- Synthetic fixtures cover initial/empty baselines, restart, corrupt/full future
  schemas, invalid/oversized input, private-field absence, filesystem permissions,
  interrupted-file cleanup, atomic-write failures, failed commit/retry, stable IDs,
  ordering, source add/remove/replace, identity isolation, repository visibility
  gaps, truncation, source failure, review conflicts/enrichment, unknown decisions,
  bots, individual/overall review deduplication, dismissed/superseded states and drafts.
- Shared-coordinator tests exercise simultaneous triggers, manual/popover/automatic
  loads, stale cancelled discovery after sleep/disconnect, partial success, persistence
  failure/recovery and replacing the sole callback. Actor tests cover out-of-order
  input and cancellation before/during commit. Existing Phase 5A tests retain virtual
  scheduling, replacement/draining, shutdown, watchdog, rate-limit and wake coverage.
- Apple Development-signed **arm64 Debug build succeeds** with Swift 6, complete
  strict concurrency and Swift warnings as errors. The standard Xcode AppIntents
  metadata-extraction notice remains; no Swift compiler warnings occur.
- Signed bundle, sandbox, outbound network, private Keychain group/profile, ATS,
  arm64 and two-second startup smoke checks pass. The smoke check stops only its
  own instance. Diff/whitespace and tracked-text credential-pattern checks pass.

Reproduce with the existing local signing configuration:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase5B \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES SDK_STAT_CACHE_ENABLE=NO \
  SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES test
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase5BSigned \
  SDK_STAT_CACHE_ENABLE=NO SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
sh scripts/validate-app.sh build/Phase5BSigned/Build/Products/Debug/pingit.app
sh scripts/validate-launch.sh build/Phase5BSigned/Build/Products/Debug/pingit.app
```

Xcode compiler/test/signing and launch checks require normal macOS service access.
Products and logs remain ignored under `build/`, including `phase5b-tests.log` and
`phase5b-signed-build.log`. The unrelated `artwork/website/` directory is preserved.

## Live validation and limitations

No real GitHub event transition was observed or manufactured. Startup survival is
verified; live private discovery, physical sleep/wake, and real permission changes
were not inspected. No credential was exported, no GitHub PR was modified, and no
new GitHub query was added. Intel/Release, VoiceOver and UI acceptance were not rerun.

GitHub search is eventually consistent, not a transactional repository inventory.
Complete pagination plus same-source repository witnesses is the strongest removal
evidence available from the existing queries; index omissions cannot be eliminated.
The last request in an otherwise unwitnessed repository can remain pending forever.
Unobservable close/reopen/re-request cycles and transitions within one GitHub update
timestamp may be missed. Review submissions have no fetched submission timestamp;
metadata enrichment is suppressed using stable scopes, complete comparable sets,
review IDs and increasing PR update time, rather than inventing history. Changes
across incomplete/conflicting data or affected token scopes may be intentionally
missed while a trustworthy baseline is reestablished. Retained inaccessible state
can eventually hit the storage cap, which fails closed without eviction.

Recommended next phase: review this event contract and perform signed live read-only
acceptance, then separately scope the notification work planned for Phase 5D. Native
notification delivery/permissions and any activity feed still need explicit scope.

## Incremental commits

- `faf4c02` — event and minimal snapshot domain models.
- `799a6ea` — private bounded versioned atomic storage.
- `b862b46` — conservative request/draft/review comparisons.
- `93f2e36` — shared refresh integration, ordering and source reconciliation.
- `4092f92` — detector/storage/lifecycle tests and final coverage safeguards.
- `f77308e` — namespace event IDs across corrupt/incompatible baseline resets.
- This report is committed separately; see `git log`. Nothing was pushed and no
  pull request was created.
