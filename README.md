# pingit

A native macOS menu bar app that keeps your GitHub pull requests and review requests close at hand.

Check reviews, follow your own PRs, and open a pull request on GitHub without leaving a browser tab open all day. Built with SwiftUI, with no external package dependencies or backend service.

**Early development.** Build from source for now. The signed release and Homebrew
packaging workflow is documented in [Distribution](docs/distribution.md); the
first public binary release is being prepared.

## Features

- **Three inboxes:** Review for direct review requests, My PRs for your open pull requests, and Drafts for work in progress.
- **PR context at a glance:** repository, review status, last update, and files changed with addition/deletion totals.
- **Attention labels:** direct review requests and changes requested on your PRs appear first within their inbox.
- **Multiple tokens, one GitHub account:** combine access to personal and organization repositories, with duplicate PRs removed within each inbox.
- **Background sync:** refresh every 5 minutes by default, even when the popover is closed. Choose 2, 5, 10, 15, or 30 minutes, or disable it in Settings. The app must stay running.
- **Optional native notifications:** review requests, approvals, requested changes, relevant comments and thread replies, and merge/close/reopen events for previously observed authored PRs. Event types can be configured individually; bot comments are off by default.
- **Manual refresh and keyboard access:** refresh with ⌘R and switch inboxes with ⌘1–3.

## Requirements

- macOS 14 or later, on Apple Silicon or Intel.
- Full Xcode with Swift 6 support. CI uses Xcode 26.3; see [toolchain details](docs/ci.md).
- A GitHub.com account and a personal access token for the repositories you want to follow.
- A valid Apple Development signing identity and provisioning profile to connect an account using the app's Keychain storage. The committed development team does not provide signing assets for your machine.

## Build and run

```sh
git clone https://github.com/birosrichard/pingit.git
cd pingit
open pingit.xcodeproj
```

1. Select the shared **pingit** scheme and **My Mac** destination.
2. In the app target's **Signing & Capabilities**, select your development team and keep automatic signing, Keychain Sharing, and App Sandbox enabled. Use your own bundle identifier if needed.
3. Let Xcode create a provisioning profile, then run with **⌘R**.

pingit appears in the menu bar. There is no main window or persistent Dock icon. Open the menu bar popover to connect GitHub or access **Settings…**.

If Xcode reports **Provisioning Profile: None Required**, or the app reports a Keychain signing error, check that you have a valid Apple Development identity and a profile for your team and bundle identifier. Selecting a team alone is insufficient. Changing the bundle identifier also changes the credential service and Keychain group; the new build will not reuse the original build's saved tokens.

### Preview without a signing team

You can inspect the UI with an ad hoc build. This build cannot use the provisioned Keychain connection, so connecting a real GitHub account requires the development build above.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project pingit.xcodeproj -scheme pingit \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/ValidationDebug \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  DEVELOPMENT_TEAM= PROVISIONING_PROFILE= PROVISIONING_PROFILE_SPECIFIER= build
open build/ValidationDebug/Build/Products/Debug/pingit.app
```

After rebuilding a running app, quit its old instance and relaunch it to load the new executable.

## Connect GitHub

1. Create a [fine-grained personal access token](https://github.com/settings/personal-access-tokens/new) with an expiration. Choose the resource owner and repositories you want pingit to access. Grant **Pull requests: Read-only** and accompanying **Metadata: Read-only** for private PRs. No write permissions are needed.
2. Choose **Connect GitHub**, or open **Settings… → GitHub tokens → Add GitHub token**.
3. Enter an owner label, paste the token into the secure field, and choose **Validate and add**.
4. To follow repositories owned by another organization or your personal account, add another token for that owner. All tokens must authenticate the same GitHub user.

Owner labels help you identify connections; they do not filter searches or verify repository access. An organization may require token approval. Successful account validation and empty search results do not prove that private repositories are accessible.

Use **Replace token** for expired or revoked credentials. Removing a connection deletes its local credential; revoke the token separately on GitHub when you no longer need it.

See [token storage and connection behavior](docs/tokens.md) and [discovery coverage](docs/discovery.md) for details.

## What attention labels mean

Review status and attention are separate signals. **Approved** describes GitHub's overall review decision; it does not establish merge readiness.

| Label | Current meaning |
| --- | --- |
| Needs attention | You have an active direct review request, or GitHub's overall review decision requests changes on your PR. |
| Waiting on others | Your non-draft PR is awaiting review or approved, or another author's PR has no active direct review request for you. No supported action was identified for you. |
| Work in progress | Your PR is a draft. |
| Attention unknown | Required metadata is missing, discovery is incomplete, or token observations conflict. |
| Previous data | The row is retained from an earlier observation and its next action is unverified. |

**“Waiting on others” does not identify a specific person or blocker.** The classifier does not consider CI, merge conflicts, or discussions when assigning attention. An approved PR with conflicts can therefore still receive this label. Check GitHub for merge readiness and outstanding work.

The menu bar icon indicates connection presence. Tab counts show displayed PRs, including retained rows; they are not action or unread counts. See [attention rules](docs/phase-7a.md).

## Current limitations

- GitHub.com only, with one identity across all configured tokens. OAuth, multiple identities, and GitHub Enterprise Server are not supported.
- The Review inbox follows active direct user requests, not team review requests.
- Results depend on token visibility, organization approval, and bounded API queries. Incomplete results and failed refreshes are surfaced; previously loaded rows may remain visible.
- CI status is currently hidden from the dashboard. The retained CI implementation and token limitations are documented in [CI metadata](docs/checks.md).
- Comment and lifecycle notifications use polling and bounded tracking. They are not a complete activity history, unread tracker, or guarantee of delivery. The first sync establishes a baseline rather than notifying about old activity.
- There are no in-app review, comment, or merge actions. PR links and notification clicks open GitHub.

## Privacy and security

pingit talks directly to GitHub. It has no analytics or backend service and does not write to GitHub.

- **Tokens:** stored in the macOS Data Protection Keychain, restricted to the app's provisioned access group, available only while the device is unlocked, and excluded from Keychain synchronization. Saved tokens are never loaded back into the input field.
- **Local settings:** non-secret connection metadata, sync settings, and notification preferences are stored in UserDefaults.
- **Change detection:** a minimal snapshot in the app's sandboxed Application Support directory stores identifiers, timestamps, review/draft/lifecycle states, and comment IDs. It excludes tokens, PR titles, repository names, URLs, and comment bodies.
- **Networking:** authenticated API requests use an ephemeral HTTPS session with disk caching and cookies disabled and redirects rejected. Public avatars load separately without a token.
- **Notifications:** disabled by default and require explicit macOS permission. When enabled, private PR metadata may appear in Notification Center and be retained by macOS.

For implementation details, see [token storage](docs/tokens.md), [notification behavior](docs/phase-5c.md), [comment tracking](docs/phase-6a.md), and [lifecycle tracking](docs/phase-6b.md).

## Development

The app uses Swift 6 with complete concurrency checking and warnings treated as errors. There are no external packages to install.

| Path | Purpose |
| --- | --- |
| `pingit/App/` | App lifecycle and shared connection state |
| `pingit/Core/Authentication/` | GitHub client, token management, and Keychain storage |
| `pingit/Core/GitHub/` | PR discovery, attention rules, sync, and change tracking |
| `pingit/Core/Notifications/` | Notification preferences and delivery |
| `pingit/Features/` | Menu bar dashboard and Settings UI |
| `pingitTests/` | Swift Testing suites with mocked networking and Keychain operations |
| `Configuration/App.xcconfig` | Bundle identifier, version, and build settings |

### Validation

Run the same build and mocked test suite used by CI on macOS, without a signing team or live credentials:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/ci-macos.sh
```

Run portable repository checks:

```sh
python3 scripts/validate-static.py
git diff --check
```

For an ordinary preview build created above, inspect its bundle and smoke-test launch from a logged-in macOS desktop session:

```sh
sh scripts/validate-app.sh build/ValidationDebug/Build/Products/Debug/pingit.app
sh scripts/validate-launch.sh build/ValidationDebug/Build/Products/Debug/pingit.app
```

The automated tests use mocked services and do not access your real Keychain or GitHub account. Passing them does not verify live token permissions, provisioned Keychain access, native notifications, or visual accessibility. Those require manual checks. See [CI and local validation](docs/ci.md).

## Contributing

Bug reports and focused pull requests are welcome. For a bug report, include your macOS and Xcode versions, what you expected, what happened, and reproduction steps. Redact tokens and private repository information from logs and screenshots.

Keep changes small, add tests for behavior changes, and run the relevant checks above. A documentation-only change does not require an app build. Read the [architecture](docs/architecture.md) and [roadmap](docs/roadmap.md) for project context; the phase documents preserve implementation notes and historical validation details.
