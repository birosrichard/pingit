# Architecture

pingit is a macOS 14+ SwiftUI menu bar utility built with Swift 6 and complete
concurrency checking. It has one application target, one unhosted unit test target,
and no external dependencies.

- `pingit/App/` owns the SwiftUI lifecycle, scenes, and shared connection lifetime.
- `pingit/Core/Authentication/` owns the shared API client, Keychain store, and connection state.
- `pingit/Core/GitHub/` holds PR domain values, independent of SwiftUI and transport envelopes.
- `pingit/Features/MenuBar/` owns the native PR dashboard, popover, and connection status.
- `pingit/Features/Settings/` owns native connection setup and secure token management.
- `pingit/Resources/` holds Info.plist and sandbox entitlements.
- `pingitTests/` contains mocked authentication, discovery, review, and dashboard lifecycle tests.
- `Configuration/App.xcconfig` centralizes bundle identity, versions, and build policy.

## Scenes and connection lifetime

`PingitAppDelegate` owns one `GitHubConnection`. At launch it starts the dashboard
scheduler and one credential-restoration task, independently of either view appearing.
`PingitApp` injects that same observable connection into the window-style
`MenuBarExtra` and native `Settings` scene. The delegate observes workspace sleep/wake
and cancels owned work/removes observers on termination.
There is no `WindowGroup`. `LSUIElement` avoids a persistent Dock icon/main window.

`GitHubConnection` is `@MainActor` and `@Observable`, owning the connection list
and one dashboard. Each connection has a stable UUID, optional authenticated GitHub
user ID/login, configured owner label, validation status/date, and a credential
reference. All connections belong to one identity. Owner labels are user supplied,
not inferred from `/user`. Failed saved credentials remain replaceable/removable.

`GitHubConnectionMetadata` persists only non-secret metadata in sandboxed UserDefaults.
Migration and deletion intent survive interruptions; Keychain holds every token.
The [token storage document](tokens.md) specifies ordering, recovery and limitations.
Adding/replacing validates before saving. Removal invalidates the current generation;
cancelled or late validation cannot restore a removed connection. Failed deletion
preserves the current UI session for retry. Duplicate validations are blocked.

`GitHubConnectionControls` displays native rows with owner, username, validation status,
Replace and confirmed Remove actions. The add flow holds an unsaved secure token draft,
clears it before submission/disappearance, and never reloads saved credentials into
views. Settings and the disconnected popover share these controls. Menu bar Settings,
Refresh (⌘R), and Quit actions remain on the main actor. Background scheduling is
independent of both views; see [Phase 5A](phase-5a.md).

## API and credential boundaries

`GitHubClient` uses Foundation URLSession and a fixed HTTPS `GET /user` endpoint.
Its ephemeral production session has no disk cache/credential storage or cookie
acceptance, bounded timeouts, and rejects every redirect. It decodes user ID when available, username,
and HTTPS avatar URL. HTTP authentication, forbidden, primary/secondary rate limit,
network, and unexpected-response failures become fixed messages; raw errors and
server bodies never reach the UI. Avatar requests are separate and unauthenticated.
The successful `/user` response proves identity, not repository/organization access.

`GitHubClient.graphQL` adds fixed-endpoint HTTPS `POST /graphql` using the same
session, header validation, and sanitized transport handling as account validation.
Callers supply the existing Keychain token per request; the client retains no token
and does not own credential storage or invalidation. Variables are `Encodable & Sendable` and
response data is `Decodable & Sendable`. The dashboard state layer invokes discovery
on opening, manual refresh and scheduled sync.

GraphQL errors are inspected before typed data decoding. Responses containing both
non-null data and errors throw `partialData`; partial results are deliberately not
returned. Missing/null data without errors throws `missingData`. Other query errors
throw `graphQLFailure`. Rate-limit failures take precedence, including HTTP 200
errors identified by headers, error type/code, or rate-limit messages. A successful
response with zero remaining quota still returns its data. HTTP 401, 403, 429 and
other statuses remain distinct from malformed JSON/schema failures. No server
message, raw decoding error, or transport error is exposed. Cancellation is checked
before transport and after it, and URLSession cancellation remains CancellationError.
The transport never retries internally; discovery owns bounded search pagination.
A shared per-token rate gate retains only token digests and monotonic restriction
deadlines in memory. It stops later pages after a limit (including a successful last
quota response), while another token can continue. Reliable server deadlines travel
in sanitized errors to the dashboard coordinator. Headerless secondary limits retain
their distinct error so the coordinator applies exponential backoff.

Domain models contain repository/PR identity, display metadata, optional review/check
status, and user/team review requests. Missing status/requests mean unavailable or
not loaded; an empty request list means a known empty result. Deleted authors have
an optional login. Codable uses domain names, not GraphQL connection shapes;
query DTOs map into these values. Domain Codable decoding uses caller date strategies;
the discovery mapper handles GitHub ISO-8601 timestamps directly.
Discovery maps GitHub's authoritative overall review decision and bounded latest
non-pending reviewer states, with per-PR detail limitations. It never calculates
review rules or merge readiness. CI and diff totals are independent head-bound metadata;
see [CI semantics](checks.md) and [review semantics](reviews.md).

`GitHubPullRequestDiscovery` is a stateless Sendable value around the existing client.
It accepts the validated account and Keychain token per call, verifies `viewer.login`,
and queries authored open PRs (including drafts) or direct pending review requests
(excluding drafts/own PRs). Transport DTOs live in `GitHubPullRequestSearch.swift`.
Result values carry token visibility/team coverage limits independently of pagination
truncation. `PullRequestDashboard` reuses this service for both sections. See
[discovery](discovery.md) for query semantics, request bounds, permissions and limitations.

`KeychainCredentialStore` uses the Security SecItem APIs against the macOS Data
Protection Keychain. Each generic password item uses the bundle-specific service
and an independent UUID account reference. It is nonsynchronizing and accessible only when unlocked,
with `ThisDeviceOnly` protection. Duplicate items update atomically; a missing item
on removal is success. The provisioned app requests its own Keychain access group
through Keychain Sharing. Ad hoc UI builds use separate preview entitlements without
that restricted group, so they can launch but report a signing error for Keychain.
Real credential use requires a valid Apple Development signing identity and profile.
The prior single-token Data Protection item is migrated conservatively; there is no plaintext fallback. No development team/credentials
are committed.

App Sandbox permits outbound networking only. It grants no file access, network
server access, or temporary exceptions. ATS remains enabled with no overrides.
Hardened runtime remains configured (Xcode disables it for ad hoc builds).

## Test boundaries

A test-only URLSession can be supplied to the concrete API client. The concrete
Keychain store accepts four narrow Security operation closures, so tests can check
actual query attributes and lifecycle without touching the user's Keychain.
Connection tests compose these concrete types. No networking protocols, generic
repositories, containers, or dependency frameworks are introduced. Dashboard tests inject narrow
credential, clock, and async discovery closures, including controlled late completions.

The unhosted test bundle compiles the same authentication, domain, and dashboard state source files rather
than launching `PingitApp`; tests cannot trigger startup credential restoration or
real network requests. Provisioned Keychain access and visual interactions require
a manual pass with a signed app. Xcode test action entitlement injection is checked
separately from ordinary Debug/Release product entitlements. A separate launch smoke
check catches macOS launch-time rejection; static signature checks alone are insufficient.

## Dashboard state and refresh

`PullRequestDashboard` keeps per-connection, per-section results/errors/coverage and
success timestamps. Refresh loads each credential once and schedules at most two
connection workers (two concurrent section queries per worker). The stateless client
receives that token explicitly on every page; no global Authorization/rate-limit state
exists. A scope's failure retains its prior in-memory data and never becomes a
successful empty result. Results from other scopes still publish independently.

Aggregated lists merge by PR node ID separately within each section; conflicts remain
unknown and warn about incomplete metadata. Removal immediately recomputes the union
from remaining sources; replacement drops its old source cache. Generation and
cancellation checks reject stale responses. Opening uses the existing 60-second
freshness threshold; explicit refresh and connection changes bypass it while still
respecting per-token rate restrictions. Requests coalesce into the active flight;
identity changes invalidate/cancel it and queue one follow-up after workers drain.
A two-minute watchdog bounds the production cancellation-aware refresh pipeline.
Per-token success completion sets its next interval deadline; failures set independent
retry deadlines. One event-driven `ContinuousClock` sleeper selects the earliest
eligible token, with no catch-up bursts. Manual and popover loads reset those same
deadlines. Sleep cancels active discovery and the deadline; wake reevaluates staleness
and restrictions. Native Settings persist only enabled/interval preferences. If the
popover opens during restore, discovery starts when connections arrive. A full
disconnect clears results and starts the next session idle. Phase 5B persists only
minimal identifier/state baselines, as described below. See [merge/lifecycle policy](tokens.md) and [dashboard](dashboard.md).

## Pull request change detection

The shared refresh flight sends only freshly successful per-source section results
into `PullRequestChangeDetector`, an actor serializing comparisons and snapshot
commits outside the main actor. Connection generations, refresh sequence ordering,
and the existing cancellation/session guards reject obsolete work. Failed/truncated
sections preserve their baseline; repository-access witnesses and stable source
coverage protect request removals and token reconciliation.

A bounded versioned JSON snapshot in Application Support persists identifiers,
state and comparability flags, omitting titles, repository names, URLs, credentials
and event history. Private atomic writes commit before `dashboard.onChanges`, the
single replaceable callback consumed by Phase 5C notification code. No consumer means events
are discarded, with no replay buffer. First sync and corrupt/incompatible storage
quietly baseline; restart resumes committed comparisons. Delivery is at most once;
a crash/cancellation between commit and callback can lose an event. See
[Phase 5B semantics, privacy, validation and limits](phase-5b.md).

## Future boundaries

Phases through 4C, [5A background sync](phase-5a.md), and
[5B change detection](phase-5b.md) are implemented. Successful
account validation must never imply complete repository access. Synchronization
stops on disconnect/quit and can be disabled. Notifications,
repository selection, multiple accounts, OAuth and packaging require separate scope.

Work stays on `main` in small local commits. Distribution, notarization, store
assets, and packaging remain Phase 8 work.

## Platform references

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Settings scene](https://developer.apple.com/documentation/swiftui/settings)
- [Open Settings action](https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings)
- [LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
- [macOS Keychain implementations/signing](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
- [Default private Keychain group](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)
- [Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
- [Authenticated GitHub user](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)
- [GitHub GraphQL requests and variables](https://docs.github.com/en/graphql/guides/forming-calls-with-graphql)
- [GraphQL rate-limit failures](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)

## Phase 4A metadata

The existing discovery queries retrieve PR diff totals and one PR head commit's
check/status rollup with connection-wide state counters. DTO normalization verifies
head identity and counter consistency. `GitHubCheckSnapshot` is independent of the
review decision and never represents merge readiness. Optional CI GraphQL failures
can recover only by discarding the affected CI subtree; rate limits and unrelated
partial errors retain strict source failure behavior. Metadata reconciliation uses
all newest observations to keep multi-token conflicts independent of order. No
new request lifecycle, persisted private metadata, polling or dependency is added.
See [detailed CI and diff policy](checks.md) and [validation](phase-4a.md).

## Phase 4B presentation boundary

`MenuBarView` retains the existing connection/dashboard lifecycle and owns local
selection, focus and measured list height. `PullRequestRow` is shared by every
inbox. The Foundation-only `PullRequestRowPresentation` projects identity, review
or author context, diff totals, canonical links and accessibility descriptions;
it deliberately does not project CI. Its focused tests compile in the existing
unhosted target. `PullRequestEmptyPresentation` preserves distinct loading, empty
and failed states. Shared spacing constants remain local to the native dashboard.

The list alone scrolls; measured content fits shorter lists and remains bounded by
420 points and the available screen height. A changed tab recreates only its
scroll view, resetting scroll position without a new discovery request. Existing
validated public owner-avatar lookup is reused with a native repository fallback.
The CI implementation is unchanged. Only its default row presentation and warnings
caused solely by `checkDataUnavailable` are suppressed; raw coverage metadata,
real source errors, truncation and metadata conflicts remain. See [Phase 4B](phase-4b.md).

## Phase 5C notifications (macOS validation pending)

The application delegate retains a native notification delegate from will-finish-launch
through termination and owns the main-actor notification coordinator/service. Settings
share that coordinator. Committed Phase 5B batches enter its sole `onChanges` consumer;
refresh invalidation also cancels pending notification work. A mockable main-actor
service owns authorization and delivery; native delegate callbacks transfer only value
payloads to main-actor URL activation. Permission requests are explicit user actions.

Seven Boolean preferences persist in UserDefaults. Payloads and bounded deduplication
IDs remain in memory; notification content is handed to macOS and may be retained by
Notification Center. The Phase 5B snapshot and credential boundaries are unchanged.
See [behavior, privacy, tests and macOS acceptance](phase-5c.md). No macOS compilation,
test execution, signing or notification delivery was performed for Phase 5C on Linux.
