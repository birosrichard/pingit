# Architecture

## Phase 1 decisions

pingit is a macOS 14+ SwiftUI menu bar utility built with Swift 6 and complete
concurrency checking. It has one application target and no dependencies.

- `pingit/App/` owns the SwiftUI lifecycle and scenes.
- `pingit/Features/MenuBar/` owns the popover and its disconnected state.
- `pingit/Features/Settings/` owns the native Settings view.
- `pingit/Resources/` holds the Info.plist and sandbox entitlements.
- `Configuration/App.xcconfig` centralizes bundle identity, versions, and build policy.

Use a window-style `MenuBarExtra` for the popover and a native `Settings` scene.
Set `LSUIElement` so there is no persistent Dock icon or initial main window.
Keep App Sandbox and hardened runtime enabled, with no network or file permissions
in this phase. Use semantic styles so the interface follows system appearance.

Views need no model layer until real state exists. Do not add service protocols,
dependency injection containers, persistence, polling, or authentication stubs.

The repository starts empty on `main`; work stays on that branch in small commits.

## Scene behavior

`PingitApp` creates the menu bar scene and Settings scene, with no `WindowGroup`.
`MenuBarView` shows only the disconnected state. Refresh is disabled, Settings
uses SwiftUI's `openSettings` action after activating the agent app, and Quit
terminates through AppKit. `SettingsView` reads version/build from the app bundle.
These UI actions execute on the main actor; there is no background work yet.

## Planned boundaries

Add authentication and Keychain credential handling in Phase 2. GitHub API work
should live outside the views and use asynchronous calls, with UI state isolated
to the main actor. Add concrete types when required; introduce protocols only
where a real replacement or test boundary needs them. Polling and notification
delivery belong outside view lifetimes and must be cancellable on disconnect/quit.
Preferences and repository selection follow in their own phase.

Both distribution paths should share this sandboxed app target. Signing,
notarization, store assets, and packaging are Phase 8 work. There are no GitHub
tokens, network entitlements, stored preferences, or placeholder services in
Phase 1.

## Platform references

- [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Settings scene](https://developer.apple.com/documentation/swiftui/settings)
- [Open Settings action](https://developer.apple.com/documentation/swiftui/environmentvalues/opensettings)
- [LSUIElement](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)
