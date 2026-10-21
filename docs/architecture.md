# Architecture

pingit is a macOS 14+ SwiftUI menu bar utility built with Swift 6 and complete
concurrency checking. It has one application target, one unhosted unit test target,
and no external dependencies.

- `pingit/App/` owns the SwiftUI lifecycle, scenes, and shared connection lifetime.
- `pingit/Core/Authentication/` owns the API client, Keychain store, and connection state.
- `pingit/Features/MenuBar/` owns the popover and connection status.
- `pingit/Features/Settings/` owns native connection setup and the shared account view.
- `pingit/Resources/` holds Info.plist and sandbox entitlements.
- `pingitTests/` contains mocked authentication and credential lifecycle tests.
- `Configuration/App.xcconfig` centralizes bundle identity, versions, and build policy.

## Scenes and connection lifetime

`PingitApp` owns one `@State` instance of `GitHubConnection`, starts a single startup
restoration task independently of either view appearing, and injects the same
observable object into the window-style `MenuBarExtra` and native `Settings` scene.
There is no `WindowGroup`. `LSUIElement` avoids a persistent Dock icon/main window.

`GitHubConnection` is `@MainActor` and `@Observable`. Only nonsecret account data,
busy state, credential presence, and sanitized error text reach the views. Connect
validates before saving; a storage failure cannot become a connected state.
Restoration reads Keychain and validates once per launch. Transient failures retain
the credential for explicit retry. Unauthorized saved tokens are deleted, with
removal errors reported. Disconnect only clears account state after deletion succeeds.
Duplicate attempts/disconnect are blocked during validation; cancellation cannot
commit a validated account/token. There is no background retry or polling.

The shared `GitHubConnectionControls` view holds only an unsaved token draft.
Settings embeds it in its connection section; the menu bar’s **Connect GitHub**
CTA opens the same controls in a scrollable panel with a Back action. Submission
clears the draft before the asynchronous attempt; successful connection and view disappearance clear it too.
The connected view never reads a token. The menu bar shows connection status,
Settings, disabled Refresh, and Quit. Opening Settings activates the agent app
through AppKit. These UI actions remain on the main actor.

## API and credential boundaries

`GitHubClient` uses Foundation URLSession and a fixed HTTPS `GET /user` endpoint.
Its ephemeral production session has no disk cache/credential storage or cookie
acceptance, bounded timeouts, and rejects every redirect. It decodes only username
and HTTPS avatar URL. HTTP authentication, forbidden, primary/secondary rate limit,
network, and unexpected-response failures become fixed messages; raw errors and
server bodies never reach the UI. Avatar requests are separate and unauthenticated.
The successful `/user` response proves identity, not repository/organization access.

`KeychainCredentialStore` uses the Security SecItem APIs against the macOS Data
Protection Keychain. One generic password item uses the bundle-specific service
and fixed account name. It is nonsynchronizing and accessible only when unlocked,
with `ThisDeviceOnly` protection. Duplicate items update atomically; a missing item
on removal is success. The provisioned app requests its own Keychain access group
through Keychain Sharing. Ad hoc UI builds use separate preview entitlements without
that restricted group, so they can launch but report a signing error for Keychain.
Real credential use requires a valid Apple Development signing identity and profile.
There is no legacy Keychain or plaintext fallback. No development team/credentials
are committed.

App Sandbox permits outbound networking only. It grants no file access, network
server access, or temporary exceptions. ATS remains enabled with no overrides.
Hardened runtime remains configured (Xcode disables it for ad hoc builds).

## Test boundaries

A test-only URLSession can be supplied to the concrete API client. The concrete
Keychain store accepts four narrow Security operation closures, so tests can check
actual query attributes and lifecycle without touching the user's Keychain.
Connection tests compose these concrete types. No networking protocols, generic
repositories, containers, or dependency frameworks are introduced.

The unhosted test bundle compiles the same three authentication source files rather
than launching `PingitApp`; tests cannot trigger startup credential restoration or
real network requests. Provisioned Keychain access and visual interactions require
a manual pass with a signed app. Xcode test action entitlement injection is checked
separately from ordinary Debug/Release product entitlements. A separate launch smoke
check catches macOS launch-time rejection; static signature checks alone are insufficient.

## Future boundaries

Only Phases 1 and 2 are implemented. PR/review data belongs outside views, using
asynchronous calls with cancellation, pagination, and rate-limit handling. Future
repository permissions must be documented separately; successful account validation
must never imply that those permissions exist. Polling and notifications belong
outside view lifetimes and must stop on disconnect/quit. Preferences, repository
selection, multiple accounts, OAuth, and packaging are out of this phase.

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
