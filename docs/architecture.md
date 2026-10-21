# Architecture

## Phase 1 decisions

GitPingly is a macOS 14+ SwiftUI menu bar utility built with Swift 6 and complete
concurrency checking. It has one application target and no dependencies.

- `GitPingly/App/` owns the SwiftUI lifecycle and scenes.
- `GitPingly/Features/MenuBar/` owns the popover and its disconnected state.
- `GitPingly/Features/Settings/` owns the native Settings view.
- `GitPingly/Resources/` holds the Info.plist and sandbox entitlements.
- `Configuration/App.xcconfig` centralizes bundle identity, versions, and build policy.

Use a window-style `MenuBarExtra` for the popover and a native `Settings` scene.
Set `LSUIElement` so there is no persistent Dock icon or initial main window.
Keep App Sandbox and hardened runtime enabled, with no network or file permissions
in this phase. Use semantic styles so the interface follows system appearance.

Views need no model layer until real state exists. Do not add service protocols,
dependency injection containers, persistence, polling, or authentication stubs.

The repository starts empty on `main`; work stays on that branch in small commits.
