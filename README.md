# pingit

A lightweight, native macOS menu bar app for GitHub activity. The goal is to show
pull requests, reviews, comments, and CI updates that need your attention.

**Current status: Phase 2 — GitHub Authentication.** Connect one GitHub.com account
with a personal access token, verify its identity, see its username/avatar, and
disconnect. The app restores and revalidates saved credentials at startup. Settings
and the menu bar share connection state. Refresh remains disabled; PR fetching,
review tracking, polling, and notifications are not implemented.

## Requirements

- macOS 14 or later; Apple Silicon and Intel
- Xcode 16 or later with Swift 6; validated with Xcode 26.3 / Swift 6.2.4
- An Apple Development signing identity and provisioning profile for real Keychain
  access (choose your development team in Xcode; no team is committed)

## Build and run

Open `pingit.xcodeproj`, select the shared **pingit** scheme and **My Mac**. Under
Signing & Capabilities, select your development team, keep automatic signing
and App Sandbox enabled, then Run (⌘R). The app appears only in the menu bar; no main window opens at launch.

If your shell uses Command Line Tools, select Xcode for these commands:

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
```

To build for UI inspection without selecting an Apple Developer team:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/ValidationDebug \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
open build/ValidationDebug/Build/Products/Debug/pingit.app
```

Use `arch=x86_64` on Intel. Ad hoc signing supports builds and mocked tests, but
cannot supply a provisioned Keychain identity. The app reports an actionable
Keychain error when that identity is missing. Use a development-team-signed build
to connect a real account. Do not add broad entitlements or a plaintext fallback.

Bundle identity (`dev.biros.pingit`), version, build number, and minimum macOS
version live in `Configuration/App.xcconfig`. A bundle-ID override also changes
the credential service and default private Keychain group, so it cannot restore the original
build's credential. Sandbox and hardened runtime remain configured; Xcode disables
hardened runtime for ad hoc signing. Distribution/notarization is future work.

## Connect GitHub

1. Open **Settings…** from the menu bar popover.
2. Follow [GitHub's fine-grained token instructions](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens#creating-a-fine-grained-personal-access-token):
   GitHub Settings → Developer settings → Personal access tokens → Fine-grained
   tokens → Generate new token.
3. Give the token a name and expiration, choose your own account as resource owner,
   choose **Public repositories**, and leave additional permissions unset. This
   phase needs no write permissions or private repository access.
4. Paste the token into the secure field and click **Connect**. pingit validates
   it using authenticated `GET https://api.github.com/user`, then saves it to
   macOS Keychain. A successful connection shows your username and avatar.
5. Click **Disconnect** to remove the saved credential. This removes the local
   copy; it does not revoke the token on GitHub. Revoke it in GitHub Settings if
   you no longer need it anywhere.

GitHub documents that [`GET /user`](https://docs.github.com/en/rest/users/users#get-the-authenticated-user)
requires no additional fine-grained permissions. Successful validation establishes
account identity; it does **not** prove access to private repositories or
organization resources. Future PR/review features may require additional read
permissions on selected repositories and organization approval. No such access
is requested or tested in Phase 2.

At startup, an invalid/expired saved token is removed. Offline, rate-limit, and
server failures retain the credential; **Retry saved connection** revalidates it
when you choose. A failed Keychain deletion remains visible and can be retried.

## Security

- Credentials persist exclusively in the macOS Data Protection Keychain, with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and synchronization disabled.
  The service is `<bundle identifier>.github`, account `personal-access-token`,
  in the signed app's default private Keychain group. No Keychain Sharing entitlement
  is requested; Xcode supplies the app identity for provisioned builds.
- Tokens exist transiently in memory during entry/requests. The input clears on
  submission, successful connection, and closing Settings. Saved tokens are never
  loaded back into the field or retained in the observable UI model.
- The API uses an ephemeral URLSession with disk cache, credential storage, and
  cookie acceptance disabled. Requests use a fixed HTTPS endpoint and reject
  redirects. Avatars load separately over HTTPS without an Authorization header.
- No UserDefaults/file credential storage, token logs, Authorization logging,
  analytics, embedded secrets, external dependencies, or ATS exceptions.
- Only outbound networking is allowed. Keychain access relies on signing and its
  app-specific group; no file or server sandbox entitlements are granted.

Apple recommends [Data Protection Keychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
and explains its [provisioned signing requirements](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).
A locked/unavailable keychain or missing signing entitlement is surfaced without
claiming that credentials were saved or removed.

## Validation

Run the mocked unit tests (no real token or user Keychain access):

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

The unhosted Swift Testing target compiles the same authentication sources without
launching the app. Each URLProtocol stub has an isolated session; Security calls
use in-memory operations. Tests cover account validation, request headers,
unauthorized tokens, rate limits, transport failures, bad responses, HTTPS and
redirect constraints, Keychain attributes/replacement/removal/errors, restoration,
retry, disconnect failure, duplicate attempts, and cancellation.

Build a universal Release app, then check both products:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build/ValidationRelease ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
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

Manual checks, using a development-team-signed build and a disposable token:

- Launch without a Dock icon/main window; open the popover and Settings repeatedly.
- Confirm disconnected status, disabled empty Connect, secure entry, setup link,
  and version/build; check light/dark appearance and keyboard/VoiceOver access.
- Connect; confirm progress, disabled duplicate attempts, cleared input, username
  and avatar, and matching menu bar state. Refresh must remain disabled.
- Quit/relaunch and verify saved-token restoration without re-entering the token.
- Relaunch offline; check the retry/disconnect actions and recovery when online.
- Revoke/expire the token in GitHub, then relaunch; verify its local removal and
  actionable error. Enter a new token and reconnect.
- Disconnect; verify the local Keychain item is gone and relaunch stays disconnected.
- With Keychain unavailable, verify read/save/delete errors and successful retry;
  failed deletion must not claim a successful disconnect.
- Close Settings while connecting; ensure completion and reopening remain coherent.
- Quit cleanly; also run the Release app on an Intel Mac before distribution.

After rebuilding a running app, quit its old instance and relaunch to load the new
executable. See [architecture](docs/architecture.md) and the
[eight-phase roadmap](docs/roadmap.md).
