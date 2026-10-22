# pingit

A lightweight, native macOS menu bar app for GitHub activity. The goal is to show
pull requests, reviews, comments, and CI updates that need your attention.

**Current status: Phase 5B — Reliable Pull Request Change Detection.**
Connect one GitHub.com identity with multiple tokens stored independently in macOS
Keychain. Review / My PRs / Drafts show clearer native PR rows, repository/owner
identity, independent review context and compact file/addition/deletion totals.
CI statuses are hidden from default rows, tooltips and VoiceOver while the Phase 4A
CI query, domain and tests remain intact. Unavailable CI alone no longer raises a
dashboard warning; real discovery/authentication failures and partial results remain
visible. Review approval never establishes merge readiness.

The popover retains its original fixed 440-point width, keeps header/tabs/footer
outside the scrolling list, and retains manual Refresh/⌘R and the 60-second on-open
freshness policy. Rows sit directly on the dashboard surface; native scrollbars
have a separate content inset, counts use subtle badges, and drafts do not prompt
for normal review. Submitted reviews and GitHub's authoritative data remain intact.
Background sync runs while the app is open, even with the popover closed, every
5 minutes by default. **Settings → Background Sync** can disable it or select
2, 5, 10, 15 or 30 minutes. Manual refresh remains available. Token-specific retry
restrictions protect rate limits and preserve stale results on failure. Native
notifications are opt-in under **Settings → Notifications**, with independent event
switches and explicit macOS permission. Private PR metadata may appear in macOS
Notification Center when enabled. A minimal local baseline detects direct
review-request, review and draft-ready changes across refreshes and restarts; that
baseline excludes titles, repository names and event history.
**Phase 5C is not compiled or tested on macOS — awaiting local validation.**
See [notification behavior, privacy and macOS acceptance](docs/phase-5c.md),
[change detection and validation](docs/phase-5b.md),
[background sync and validation](docs/phase-5a.md),
[Phase 4C polish and validation](docs/phase-4c.md),
[Phase 4B design and validation](docs/phase-4b.md),
[review semantics](docs/reviews.md), [retained CI implementation](docs/checks.md), and
[discovery limitations](docs/discovery.md).

## Requirements

- macOS 14 or later; Apple Silicon and Intel
- Xcode 16 or later with Swift 6; Phase 5B validated with Xcode 27.1 / Swift 6.4
- A valid Apple Development signing identity and provisioning profile for real
  Keychain access (choose a team in Xcode for which you have signing assets;
  the committed team ID alone does not provide them)

## Build and run

Open `pingit.xcodeproj`, select the shared **pingit** scheme and **My Mac**. Under
Signing & Capabilities, select your development team, keep automatic signing,
Keychain Sharing, and App Sandbox enabled. Xcode should show a provisioning
profile for the app. Then Run (⌘R). The app appears only in the menu bar; no
main window opens at launch. If Xcode shows **Provisioning Profile: None Required**
or Keychain reports a signing error, check that a valid Apple Development signing
identity is installed in Keychain Access and let Xcode create a profile for this
bundle ID. If Xcode says your Mac is not registered with the selected developer
account, resolve that in Xcode's Signing & Capabilities before rebuilding.
Selecting a team alone does not provide Keychain access.

If your shell uses Command Line Tools, select Xcode for these commands:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

To build for UI inspection without selecting an Apple Developer team:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/ValidationDebug \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
open build/ValidationDebug/Build/Products/Debug/pingit.app
```

Use `arch=x86_64` on Intel. The preview entitlements let an ad hoc build launch
without a provisioning profile; its Keychain connection will report a signing
error. Use a provisioned development build to connect a real account.

Bundle identity (`dev.biros.pingit`), version, build number, and minimum macOS
version live in `Configuration/App.xcconfig`. A bundle-ID override also changes
the credential service and default private Keychain group, so it cannot restore the original
build's credential. Sandbox and hardened runtime remain configured; Xcode disables
hardened runtime for ad hoc signing. Distribution/notarization is future work.

## Connect GitHub

1. Open **Settings… → GitHub tokens → Add GitHub token**, or use **Connect GitHub**
   in the disconnected menu bar popover.
2. Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new)
   with an expiration. Select the intended resource owner and repositories.
   For private PRs grant **Pull requests: Read-only** and accompanying
   **Metadata: Read-only**. For CI, see [minimum read permissions and GitHub PAT limitations](docs/checks.md#token-permissions-and-current-github-limitations). No write permissions are needed.
3. Enter a resource-owner label (for example `birosrichard`), paste into the secure
   token field, and choose **Validate and add**. Validation calls `GET /user` before
   saving. The configured owner remains explicitly unverified.
4. Add another token with owner label `apify` for organization repositories. Both
   tokens must authenticate the same GitHub user; duplicate owner labels and tokens
   are rejected. GitHub user ID is compared when available, otherwise login.
5. **Replace token** validates a replacement without overwriting the old credential
   first. **Remove** asks for confirmation and deletes only that local connection;
   revoke the token separately on GitHub if it is no longer needed anywhere.

The dashboard combines token-visible PRs and deduplicates each section by GitHub
node ID. Authentication does not verify a token's resource owner, private repository
permissions, or organization approval. Pending approval/access restrictions may
hide private repositories without a search error. Empty results never prove complete
coverage. Each failed scope has a named error; successful scopes remain usable.

Existing users migrate automatically without re-entering a token. Invalid, revoked,
or expired saved tokens remain available for explicit replacement/removal. Offline,
permission and rate-limit failures also retain credentials. **Retry saved connections**
revalidates without automatically retrying repeatedly.

Settings shows the configured owner’s public GitHub avatar. Pull request rows show
the repository owner’s avatar. Images load without a token and fall back to a
generic icon when unavailable; an avatar does not verify token access.

See [multi-token storage, merge policy, validation and manual checks](docs/tokens.md).

## Security

- Credentials persist exclusively in the macOS Data Protection Keychain, with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and synchronization disabled.
  The service is `<bundle identifier>.github`, with separate `connection-<UUID>` accounts,
  in the provisioned app-specific Keychain access group. The development build
  requests this group through Keychain Sharing; ad hoc previews omit it.
- Tokens exist transiently in memory during entry/requests. The input clears on
  submission, successful connection, and closing Settings. Saved tokens are never
  loaded back into the field or retained in the observable UI model.
- The API uses an ephemeral URLSession with disk cache, credential storage, and
  cookie acceptance disabled. Requests use a fixed HTTPS endpoint and reject
  redirects. Avatars load separately over HTTPS without an Authorization header.
- UserDefaults stores non-secret connection metadata, migration/deletion bookkeeping,
  and sync preferences only.
  No token values, private PR content, token logs, Authorization logging,
  analytics, embedded secrets, external dependencies, or ATS exceptions.
- Only outbound networking is allowed. Keychain access relies on signing and its
  app-specific group; no file or server sandbox entitlements are granted.

Apple recommends [Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
and explains its [provisioned signing requirements](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
A locked/unavailable keychain or missing signing entitlement is surfaced without
claiming that credentials were saved or removed.

## Validation

Pull requests to `main` run the native app build and full automated suite on
GitHub-hosted macOS with pinned Xcode 26.3 and ad hoc signing. See
[macOS CI](docs/ci.md) for toolchain checks, logs, local reproduction, signing
boundaries, and Linux validation limits.

Run the mocked unit tests (no real token or user Keychain access):

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

The unhosted Swift Testing target compiles the same authentication/data sources without
launching the app. Each URLProtocol stub has an isolated session; Security calls
use in-memory operations. Tests cover account validation, request headers,
unauthorized tokens, rate limits, transport failures, bad responses, HTTPS and
redirect constraints, Keychain attributes/replacement/removal/errors, restoration,
retry, disconnect failure, duplicate attempts, and cancellation. GraphQL coverage
includes variables, HTTP 200 errors, rejected partial/missing data, HTTP failures,
rate limits, malformed responses, credential reuse, in-flight cancellation, and
domain decoding. Discovery adds query/mapping, active-request/draft filtering,
pagination/deduplication, visibility/truncation, permission failures and cancellation tests.
If Xcode stalls scanning the SDK stat cache, add `SDK_STAT_CACHE_ENABLE=NO`.

Build a universal Release app, then check both products:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/ValidationRelease ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
sh scripts/validate-app.sh build/ValidationDebug/Build/Products/Debug/pingit.app
sh scripts/validate-app.sh build/ValidationRelease/Build/Products/Release/pingit.app
sh scripts/validate-launch.sh build/ValidationDebug/Build/Products/Debug/pingit.app
sh scripts/validate-launch.sh build/ValidationRelease/Build/Products/Release/pingit.app
lipo -archs build/ValidationRelease/Build/Products/Release/pingit.app/Contents/MacOS/pingit
```

The script checks the built bundle, signature, sandbox, outbound networking,
Keychain entitlement policy, and absence of file/server/temporary/ATS exceptions.
Use a normal **build** product for this check: Xcode's **test** action injects
additional test-runner entitlements. Supply a custom bundle ID as the script's
second argument if needed. The launch check starts a separate process for two
seconds and then stops only that process; run it from a logged-in macOS desktop session. It catches launch-time
signature rejection that `codesign --verify` alone misses. Ad hoc builds must omit
restricted Keychain access groups, since macOS rejects unprovisioned groups before
app startup. Neither check proves live Keychain access or the visual UI.

For signed migration, two-token setup, refresh/removal/replacement, restart, and
keyboard/VoiceOver verification, follow the [Phase 3E acceptance checklist](docs/tokens.md#manual-acceptance).
The automated suite requires no live credentials. Live two-token coverage and visual
accessibility remain manual acceptance items.

After rebuilding a running app, quit its old instance and relaunch to load the new
executable. See [architecture](docs/architecture.md) and the
[eight-phase roadmap](docs/roadmap.md).
