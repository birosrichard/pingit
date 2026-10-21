# Phase 5C — Native macOS notifications

**Not compiled or tested on macOS — awaiting local validation.**

Implemented in T3 Code on Linux. Swift, `xcodebuild`, Apple frameworks and macOS
notification services are unavailable here. Static checks are not compilation,
automated test execution, or proof of notification delivery. Historical Phase 5B
build/test results do not validate this change. Xcode 26.3 acceptance is pending.

## Architecture

The application delegate owns one `NotificationCoordinator`, one native service,
and a strongly retained `UNUserNotificationCenterDelegate`. The native delegate is
installed in `applicationWillFinishLaunching`, before permission refresh, credential
restoration or background sync. Opening/closing the menu bar popover has no effect
on its lifetime. Notification status refresh and account restoration use separate
tasks, so notification permission lookup does not hold up GitHub restoration.

`NotificationCoordinator.start(dashboard:)` installs the existing Phase 5B
`dashboard.onChanges` callback. Only committed, fresh detector events enter it.
No GitHub query, token scope, transport, snapshot format, dashboard presentation,
or background schedule changes. The detector's quiet initial baseline, coverage
barriers, persistent deduplication and at-most-once event semantics remain intact.

Preferences, coordinator state and the injectable `NotificationService` protocol
are `@MainActor`. `NotificationMessage` and permission values are `Sendable`.
The native adapter maps settings to a value on the callback queue and bridges
completion handlers through checked continuations. Mutable native notification
objects stay in the adapter's registration scope. The Objective-C delegate has
immutable state, accepts callbacks on any queue, extracts only strings and hops to
`MainActor` for AppKit URL opening. Completion handlers are invoked once. No
`@unchecked Sendable`, `@preconcurrency`, unsafe isolation, force unwrap or unsafe cast was
added. Existing Swift 6, complete concurrency and warnings-as-errors settings remain.

## Behavior and preferences

Use **Settings → Notifications**. The master switch is **off by default**. Changing
it does not prompt for permission. Choose **Request notification permission** to
explicitly request alerts and sound. Status is read at launch, activation, Settings
appearance and before each submission. Denied and undetermined states suppress
new notifications without prompting from background work; denial directs the user
to macOS System Settings → Notifications. Returning to pingit or choosing **Refresh
permission status** reloads changes made there. Authorized and provisional states
allow submission; unknown/unavailable states fail closed. Focus, alert style,
preview and sound settings remain controlled by macOS.

| Event | Default when master is enabled |
| --- | --- |
| Direct review requested | On |
| Direct review request removed | Off |
| Pull request approved | On |
| Changes requested | On |
| Draft ready for review | Off |
| Sound | Off |

Each event toggle is independent. Notifications contain an event heading,
`owner/repository #number`, the current PR title if available, and a reviewer when
reliably supplied. Missing titles fall back to `Pull request #number`; missing
reviewers are omitted. Control/format characters are removed and title/reviewer
text is bounded. Approval never asserts merge readiness. The foreground delegate
requests banner/list presentation and optional content sound, so an active Settings
window does not itself suppress a notification.

Request identifiers hash the stable Phase 5B event ID. The per-PR hashed
`threadIdentifier` asks macOS to group related notifications; actual presentation
also depends on the user's macOS grouping preferences. Different real transitions
retain distinct request identifiers. A 512-ID memory cache reserves each accepted
event before asynchronous delivery, suppressing duplicates within/across batches
and while a submission is in flight. The pending queue holds at most 100 messages;
excess events are dropped, not stored for later catch-up. Old cache entries may be
evicted. Phase 5B's persisted baseline prevents ordinary refresh/restart replay.

Delivery is best effort, **not an outbox**. Disabled, filtered, denied, cancelled,
overflowed and failed notifications are not replayed when preferences/permissions
change. Submission errors show a fixed Settings message without raw errors or logs;
subsequent events can still deliver. A successful submission does not prove a banner
was shown. A crash after baseline commit can consume an event without an alert.

The shared refresh invalidation boundary cancels pending delivery on sleep,
connection removal/replacement and shutdown. Preference changes cancel pending
messages; assigning an unchanged preference does not. Status and cancellation are
checked after suspension and between submissions. Once a request has been handed
to macOS, cancellation cannot recall it. Existing delivered notifications are not
removed on disconnect or preference changes. Shutdown detaches callbacks, cancels
owned tasks and releases the native delegate. Wake uses the existing sync scheduler.

## Activation

Only the default click action on pingit event/Debug identifiers can activate a URL;
dismissals, unknown actions, missing/incorrectly typed payloads and foreign
identifiers are ignored. Activation works from the payload after a cold launch,
without retaining an event-to-URL history or requiring an open popover.

Both formatting and activation validate URLs. Accepted values are canonical
`https://github.com/<owner>/<repository>/pull/<positive-number>` URLs, with ASCII
repository components and a canonical integer. Credentials, explicit ports,
queries, fragments, encoded path components, trailing/subpaths, alternate schemes
and other hosts are rejected. Formatting also requires repository/number metadata
to match the URL. Only validated URLs reach the injected opener; production uses
`NSWorkspace.shared.open` on the main actor. No GitHub API writes are involved.

## Privacy

The only new application persistence is seven Boolean `notifications.*` preferences
in the existing UserDefaults domain: master, five event toggles and sound. Permission
status is read from macOS, never persisted by pingit. Tokens remain in Keychain.
The Phase 5B private snapshot is unchanged and still excludes names, titles, URLs
and reviewer logins. Pending messages and bounded hashed event IDs remain in memory;
there is no application notification history, telemetry, server, remote push, or
new credential requirement. No notification entitlement/capability was added.

**When notifications are enabled, their title, repository, number, optional reviewer
and canonical PR URL are handed to macOS.** Notification Center may retain them,
including after pingit quits/disconnects. They may appear on a locked screen depending
on the user's preview settings. This is separate from pingit's snapshot privacy
guarantees. UserDefaults Boolean preferences are not sensitive-data encryption.

## Tests and Linux verification

`pingitTests/NotificationTests.swift` uses the existing Swift Testing framework and
mock notification service/opener. Fixtures have no real credentials and never ask
macOS for permission or submit notifications. Coverage includes defaults and
Boolean-only persistence, permission states and denial, concurrent permission
requests and stale results, independent event filters, content/fallbacks, grouping,
bounded text/queue/cache behavior, duplicate suppression, failed delivery, URL and
action validation, preference/lifecycle cancellation and an actual Phase 5B
commit → callback → mock-delivery flow with a persisted-baseline restart.
The Debug sample also uses the mock in unit tests. **These tests have been written,
not executed in Linux.**

Verified on Linux:

```sh
python3 scripts/validate-static.py
git diff --check origin/main
```

The portable script checks project property-list syntax, duplicate/missing objects,
file references, app/test source membership (including all notification files),
plist/entitlement XML, shared scheme target references, asset JSON/resources,
relative documentation links, conflict markers, tracked-text credential patterns,
unsafe constructs in notification source, retained Swift settings, shell syntax,
and diff whitespace. Source/API review checked Apple declarations listed below.
No Swift compiler or macOS test runner was executed.

## Exact macOS validation commands

Open `pingit.xcodeproj` in **Xcode 26.3**, select the **pingit** scheme and **My Mac**.
Select a locally available Apple Development team/profile in Signing & Capabilities
for the existing bundle ID. Existing signing settings were not changed in this PR.
If needed, set `DEVELOPER_DIR` to the installed Xcode application:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
xcodebuild -version

# Full automated suite with mocks; preview entitlements avoid requiring a profile.
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase5CTests \
  -resultBundlePath build/Phase5CTests.xcresult \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES SDK_STAT_CACHE_ENABLE=NO \
  SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES test

# Signed app for real Keychain and notification acceptance; requires local signing setup.
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase5CSigned \
  SDK_STAT_CACHE_ENABLE=NO SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
sh scripts/validate-app.sh build/Phase5CSigned/Build/Products/Debug/pingit.app
sh scripts/validate-launch.sh build/Phase5CSigned/Build/Products/Debug/pingit.app
open build/Phase5CSigned/Build/Products/Debug/pingit.app
```

Use a fresh result-bundle path when repeating `test`; Xcode will not overwrite an
existing `.xcresult`. Use `arch=x86_64` separately for Intel acceptance. Preview/ad
hoc signing does not validate real Keychain access or stable notification identity.

## macOS acceptance checklist

- [ ] Open project in Xcode 26.3
- [ ] Resolve Swift 6 compilation errors, if any
- [ ] Build signed arm64 Debug application
- [ ] Run the full automated test suite
- [ ] Verify warnings-as-errors
- [ ] Verify code signing and entitlements
- [ ] Launch the app
- [ ] Open notification Settings
- [ ] Request macOS notification permission
- [ ] Verify authorized and denied states
- [ ] Verify notification preferences persist
- [ ] Verify a synthetic Debug notification
- [ ] Verify notification click opens the correct PR
- [ ] Verify delivery with the popover closed
- [ ] Verify background sync remains functional
- [ ] Verify no duplicate notifications
- [ ] Verify existing dashboard behavior

Practical manual steps:

1. With a signed Debug build running, open **Settings → Notifications**. Confirm
   master/sound off and the five defaults above. Enable notifications, then choose
   **Request notification permission**. Check the status and macOS prompt. Merely
   launching or toggling preferences must not prompt.
2. Choose **Send test notification**. This Debug-only button uses public
   `octocat/Hello-World #1`; it needs no GitHub token and bypasses event-specific
   switches, while respecting master, permission and sound. Verify the banner and
   Notification Center entry. Click to open that exact public PR. Repeat with
   Settings active, with the popover closed, and after quitting pingit before clicking
   a retained notification (cold-launch activation).
3. Change event toggles/sound, quit and relaunch. Verify persistence. Disable the
   master and verify the sample cannot submit. In macOS System Settings → Notifications
   → pingit, deny/allow notifications and return to pingit; verify updated status,
   no repeated prompt, and suppression while denied. Use a fresh macOS user or
   Apple's supported local permission-reset procedure to test both first-prompt
   choices; repeated authorization requests do not re-prompt after denial.
4. Connect test GitHub credentials using the existing secure UI. Let a complete
   refresh establish a quiet baseline. With permission/master and relevant toggles
   enabled, observe legitimate direct request/review/draft transitions in a test
   repository. Confirm content and the correct PR destination. Repeated manual
   and automatic refreshes/restart must not repeat a consumed event. Events while
   disabled/denied must not replay after enabling. Do not publish private payloads
   in review feedback.
5. Observe multiple events on one PR and another PR in Notification Center with
   grouping enabled. Confirm grouping per PR and that independent transitions
   remain distinct. Repeated deliberate Debug clicks are separate samples.
6. Close the popover and wait for an eligible background refresh. Verify updates
   and notifications. Exercise physical sleep/wake, token replacement/removal,
   network failure/recovery, preference changes and quit during work. Pending
   messages should be discarded; an already submitted OS request may still appear.
   Check manual refresh, stale-data/error behavior and all three dashboard tabs.
7. Check foreground/background behavior, preview privacy, sounds/Focus restrictions,
   accessibility, older supported macOS and an Intel build before broader release.

## Risks and boundaries

SDK-specific Swift 6 diagnostics, Objective-C delegate bridging, warnings-as-errors,
code signing, permission persistence and real delivery/activation need macOS
validation. Focus/notification settings can suppress UI despite a successful add.
No Linux Swift shim or platform workaround was introduced. No activity feed,
repository selection, remote push, new GitHub query or distribution work is included.
Follow-up compiler/runtime/test fixes should update the same Draft PR; this is not
production-ready and must not be merged without explicit approval.

Apple API references checked during implementation:

- [Notification authorization](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:))
- [Notification settings](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getnotificationsettings(completionhandler:))
- [Notification delegate and installation timing](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate)
- [Notification registration](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/add(_:withcompletionhandler:))
- [Thread grouping](https://developer.apple.com/documentation/usernotifications/unmutablenotificationcontent/threadidentifier)
- [AppKit URL opening](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:))
