# pingit

A lightweight, native macOS menu bar app for GitHub activity. The goal is to show
pull requests, reviews, comments, and CI updates that need your attention.

**Current status: Phase 1 — Project Foundation.** The app has a menu bar popover
with an honest disconnected state, an inactive Refresh action, Settings, and Quit.
Settings shows connection status and the app's version/build. It follows light
and dark system appearance and has no persistent Dock icon.

GitHub connection, API access, polling, notifications, and distribution are not
implemented. There are no dependencies or stored credentials/preferences.

## Requirements

- macOS 14 or later
- Xcode 16 or later with a Swift 6 toolchain; validated with Xcode 26.3 / Swift 6.2.4

## Build and run

Open `pingit.xcodeproj`, select the shared **pingit** scheme and **My Mac**, then
Run (⌘R). The bell icon appears in the menu bar; no main window opens at launch.

For a local build without an Apple Developer team:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Debug -derivedDataPath build/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
open build/DerivedData/Build/Products/Debug/pingit.app
```

If `xcode-select -p` points to Command Line Tools, select Xcode for your shell
before running these commands (adjust the path to your installation):

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
```

Bundle identity (`dev.biros.pingit`), version, build number, and minimum macOS
version live in `Configuration/App.xcconfig`. You can override the bundle ID
through an Xcode build setting or a command-line build argument. No development
team is committed. Choose your team in Signing & Capabilities for signed builds.
Sandbox and hardened runtime are configured; Xcode disables hardened runtime
for ad hoc signing. Local builds are not notarized or ready for distribution.

## Validation

After building, run the bundle smoke check:

```sh
sh scripts/validate-app.sh build/DerivedData/Build/Products/Debug/pingit.app
```

It checks the executable, bundle identity/version, agent flag, deployment target,
signature, and sandbox entitlement. Supply a custom bundle ID as the second
argument if you override it. No XCTest target exists yet: Phase 1 has only views
and scenes. Add focused tests when authentication and other stateful logic arrive.

Manual UI checks:

1. Launch the app and confirm the bell appears without a Dock icon or main window.
2. Open the popover: check the disconnected message and disabled Refresh action.
3. Click **Settings…** (or ⌘, with the popover open). Confirm it appears in front,
   shows **Not connected**, version **0.1.0**, and build **1**.
4. Close Settings and reopen it; also open it while it is already visible.
5. Close Settings and confirm the menu bar app stays running.
6. Check the popover and Settings in light and dark appearances.
7. Click **Quit pingit** (or ⌘Q with the popover open). Confirm the icon disappears.

After rebuilding a running app, quit the old instance and relaunch to load the
new executable. See [architecture](docs/architecture.md) and the
[eight-phase roadmap](docs/roadmap.md).
