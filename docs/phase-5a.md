# Phase 5A — Reliable background sync

Implemented on 2026-10-21 (Europe/Prague), without change detection, notifications,
activity history, new GraphQL fields, GitHub writes or persistent PR content.

## Architecture and scheduling

`PingitAppDelegate` owns the existing `GitHubConnection` and its shared dashboard.
Launch starts the scheduler once, registers native workspace sleep/wake observers,
and restores saved connections. Neither scene visibility nor opening the popover
is needed for synchronization. Restored/added valid connections become eligible
immediately when no data has been fetched. With no eligible connections the
scheduler has no sleeper.

`BackgroundSyncScheduler` owns one cancellable task sleeping until the earliest
per-token deadline. It is rearmed only by connection, preference, lifecycle and
refresh completion events. Its injectable clock uses `ContinuousClock` in production:
wall-clock adjustments cannot move elapsed-time deadlines, and sleep time counts.
There is no repeating timer, polling loop, job queue or catch-up burst.

The normal interval defaults to **five minutes** and runs from each token's last
successful complete refresh. Manual, popover and automatic loads update this same
schedule. Changing the interval recomputes deadlines from the existing success
instant; it does not start a second scheduler. Failed tokens instead use independent
retry deadlines. A long suspension therefore leads to one refresh of eligible tokens,
then a new deadline from completion, rather than replaying missed intervals.

## Refresh coordination and cancellation

Every trigger enters `PullRequestDashboard.refresh`; the existing bounded discovery,
credential loading, per-source results and merge pipeline are reused. At most one
refresh flight exists, with the existing maximum of two token workers, each loading
its two sections. Normal concurrent triggers **coalesce into the active flight**,
without cancellation or a redundant follow-up. Repeated identical connection events
are ignored. The Refresh button and Command-R remain available when idle.

Connection changes invalidate the generation immediately, cancel old workers, discard
removed/replaced private data and queue at most one follow-up using current credentials.
New workers start only after cancelled workers drain. Late responses cannot repopulate
old data or interfere with new cleanup. An explicit load during that drain joins the
single pending follow-up. Useful work is cancelled only for identity/lifecycle changes
or timeout, not because the popover opens or the interval changes.

A **120-second watchdog** bounds a production refresh, including pagination. It cancels
the cancellation-aware URLSession pipeline and retains any previous results with a
timeout error for unfinished sections. Manual requests join active work; after timeout
or completion a fresh manual attempt can run. The coordinator waits for cancellation
to drain rather than allowing overlapping operations. A deliberately uncooperative
injected fetch can delay that drain; late-response tests explicitly exercise this case.

## Sleep, wake and quit

`NSWorkspace.willSleepNotification` cancels the scheduled deadline and active discovery,
invalidates responses and retains previous data. No new discovery can start while the
sleep flag is set. `didWakeNotification` evaluates the same per-token deadlines and rate
restrictions. Fresh data waits for its normal deadline; stale data refreshes once. Wake
and normal scheduling share the coordinator. Disabling sync cancels the sleeper; an
already active refresh may finish, and manual/on-open refresh still works. Termination
cancels restoration, scheduler, watchdog and discovery, and removes workspace observers.

## Rate limits and failures

The client preserves reliable `Retry-After` seconds/HTTP dates and primary
`X-RateLimit-Reset` deadlines when remaining quota is zero. When both apply it uses
the later deadline. Invalid/nonfinite/unrepresentable headers are rejected. Success
with zero remaining quota still publishes the permitted result and restricts later
requests/pages. An actor shared by client copies keeps only token SHA-256 digests
and restrictions in memory, converts waiting to monotonic time, and prevents further
requests for that token during its window. Already in-flight section requests may
finish. Another token is not blocked by this token's local restriction.

Reliable server deadlines take precedence over arbitrary retry timing. Headerless
rate limits and transient failures use **60 seconds × 2^(consecutive failures − 1)**,
with 0–20% positive jitter, capped at **30 minutes**. One failure count applies per
token flight even if both sections fail. A cached headerless limit keeps its original
classification, so it cannot accidentally disable exponential backoff. Success resets
the failure count. Invalid/revoked and forbidden credentials pause automatic retries
until explicit retry or replacement. Manual refresh can bypass transient backoff and
retry authentication, but never bypasses a known rate restriction.

No retries occur inside the transport. Discovery safety bounds remain unchanged.
These choices follow [GitHub's rate-limit retry guidance](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#handle-rate-limit-errors-appropriately).
The clock and lifecycle use native [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock)
and [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace).

## Partial results, freshness and settings

Success publishes independently per source and section. Failure preserves that
section's prior in-memory result, coverage and successful timestamp, with a named
connection error. It never becomes a successful empty result. A restricted token
can remain stale while healthy tokens continue on their own five-minute cadence.
Deduplication and conservative metadata merging remain unchanged.

Opening displays cached rows immediately and retains the existing **60-second since
last attempt** freshness policy. Known rate restrictions still apply. A successful
manual or on-open refresh postpones automatic synchronization. `lastAttemptAt` records
actual attempts, while `lastSuccessfulRefreshAt` changes only after data is received.
The footer retains the oldest contributing section success timestamp; failed aggregate
sections show **Previous results**, and their tooltip retains the last successful time.
Settings labels the latest successful section receipt **Last data received**, avoiding
a claim that every connection succeeded together.

The native **Background Sync** section contains enabled (default true) and interval
(2, 5, 10, 15 or 30 minutes; default five), plus the optional last receipt time. Only
the two user choices are persisted, on changes, in UserDefaults. No success timestamp,
retry state, PR content or history is written to disk on sync. Tokens remain in Keychain.
No third-party dependency, privileged helper, launch agent or login item was added.

## Validation and reproduction

- **217 tests in 19 suites passed**, including the existing mocked authentication,
  discovery, dashboard and presentation coverage. No live credential is needed.
- Virtual-clock tests cover startup without any popover, default/custom intervals,
  disable/re-enable, repeated changes, one scheduler/flight, manual/on-open deadline
  reset, fresh cached rows, no valid tokens, shutdown, sleep/wake and missed intervals,
  replacement/addition/removal, cancelled-worker draining, stale-response rejection,
  timeout, network failure/recovery, jitter/capped backoff, primary/secondary limits,
  explicit retry deadlines, revoked credentials, partial success and unchanged stale
  timestamps. Transport mocks cover header parsing and suppression of later requests
  for one token while another continues, including successful zero-quota responses.
- Apple Development-signed **arm64 Debug build passed** with the existing bundle ID,
  development team, embedded provisioning profile and private Keychain access group.
  Resolved settings: Swift 6, `SWIFT_STRICT_CONCURRENCY=complete`, Swift warnings as
  errors. Compiler invocations confirm Swift 6 and warnings as errors. Xcode's standard
  AppIntents metadata-extraction notice remains; there are no Swift compiler warnings.
- Strict signature, bundle, sandbox, outbound network, Keychain group/profile policy,
  ATS and arm64 checks passed. The two-second signed launch smoke test passed without
  opening the popover and stopped only its own process.
- Tracked-source credential-pattern and phase whitespace/diff checks passed without
  printing credential values. Unrelated `artwork/website/` content was preserved.
  Concurrent Phase 4C commits were preserved. No push or PR was created.

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase5A \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES SDK_STAT_CACHE_ENABLE=NO test
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase5ASigned \
  SDK_STAT_CACHE_ENABLE=NO SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
sh scripts/validate-app.sh build/Phase5ASigned/Build/Products/Debug/pingit.app
sh scripts/validate-launch.sh build/Phase5ASigned/Build/Products/Debug/pingit.app
```

Xcode compiler plugins/test services and certificate trust/launch checks require
normal local macOS service access outside the restricted shell sandbox. Logs and
products are ignored under `build/`: `phase5a-tests.log`, `phase5a-signed-build.log`,
`Phase5A/Logs/Test/`, and `Phase5ASigned/Build/Products/Debug/pingit.app`.

## Live validation limits and next phase

The signed smoke check proves startup survival, not successful private-token discovery
or a real five-minute cycle. **No real five-minute background cycle, physical sleep/wake,
Settings interaction or live personal/organization recovery was verified in this pass.**
Virtual time verifies background refresh behavior with no popover, including long sleep,
without manufacturing rate limits or exporting Keychain credentials. Intel/Release,
older Xcode compatibility, keyboard/VoiceOver and idle CPU profiling were not rerun.

Manual acceptance: launch the signed build with saved tokens, leave the menu closed
for at least five minutes, then verify already populated data and timestamps; exercise
Settings interval/disable/re-enable, manual refresh while disabled, and one real laptop
sleep/wake. Allow naturally occurring errors to verify named stale-source behavior.
Do not exhaust quota or revoke credentials merely to manufacture failures.

Next: finish that signed live acceptance, then separately scope **Phase 5B in-memory
change detection** if desired. Notification delivery/permissions and persistent history
remain future work and require explicit instruction.

## Incremental commits

- `d92b150` — scheduling/clock/preferences/backoff primitives and build membership.
- `41fa593` — shared refresh coordinator, watchdog and per-token rate restrictions.
- `9ecc100` — application lifetime, sleep/wake and native Settings.
- `9d57c1e` — virtual-clock lifecycle and HTTP rate-limit tests, retry hardening.
- `a7985cc` — clear loading during shutdown and reject late results.
- Documentation follows in its own commit; see `git log`.
