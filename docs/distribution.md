# Distribution and Homebrew

pingit uses a universal macOS app ZIP published in GitHub Releases and a cask in
[`birosrichard/homebrew-tap`](https://github.com/birosrichard/homebrew-tap).
The first public binary release is pending signing/notarization and install checks.
Until that release is published, use the README's source build instructions.

## Signing setup (once per signing Mac)

The release requires full Xcode, a paid Apple Developer team, and a **Developer ID
Application** certificate with its private key in the login Keychain. The current
project's team is `RFX75MU9SU`. Xcode must be signed in with access to that team
and the `dev.biros.pingit` App ID. Xcode exports with automatic signing so it can
obtain a **Developer ID provisioning profile** that authorizes the restricted
Keychain access group; a development profile is insufficient for public release.
See [Apple's distribution-signing guide](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/).

Create an [app-specific password](https://support.apple.com/en-us/102654), then
store notarization credentials securely and interactively:

```sh
xcrun notarytool store-credentials pingit --team-id RFX75MU9SU
```

Enter the Apple Account associated with the team and its app-specific password at
the prompts. Do not put the password in a command argument, source file, or chat.
An App Store Connect API key can alternatively be stored through `notarytool`.
Credentials stay on the signing Mac; this workflow does not upload them to Actions.

## Build a release

1. Set `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in
   `Configuration/App.xcconfig`. Use a stable `major.minor.patch` version.
2. Run `bash scripts/ci-macos.sh`, `python3 scripts/validate-static.py`, and
   `python3 scripts/test-generate-cask.py`. Commit the release source before
   building so the release tag can identify exactly what shipped.
3. Run:

   ```sh
   RELEASE_TEAM_ID=RFX75MU9SU NOTARYTOOL_PROFILE=pingit bash scripts/release-macos.sh
   ```

The script archives Release for **arm64 and x86_64**, exports with Developer ID
signing, verifies the signature, Hardened Runtime, provisioning and Keychain
entitlements, submits to Apple's notary service, requires an accepted result,
staples the ticket, and checks Gatekeeper. It creates these files only after those
steps succeed:

- `build/release/pingit-VERSION.zip`: final app ZIP with the notarization ticket.
- `build/release/pingit.rb`: cask with the bundled version and final ZIP's SHA-256.

Diagnostics and the Xcode archive remain in `build/release/run.*`. Builds and
credentials are excluded from Git. Reusing a version with an existing final ZIP
fails: bump the version instead of replacing published release assets. A failure
before notarization must never be worked around by publishing a preview build or
removing Gatekeeper quarantine.

## Publish and check the download

For version `0.1.0` (change the version and source commit for later releases):

```sh
gh release create v0.1.0 build/release/pingit-0.1.0.zip \
  --repo birosrichard/pingit --target SOURCE_COMMIT_SHA \
  --title 'pingit 0.1.0' --generate-notes --draft
```

Download the draft asset with `gh release download` to a temporary directory,
compare its SHA-256 with the local ZIP, unzip it, and rerun `validate-app.sh`,
`codesign --verify --deep --strict`, `xcrun stapler validate`, and
`spctl --assess --type execute`. Smoke-test launch, connecting GitHub, token
restoration after relaunch, and notifications with the exported app. Do not log
tokens or private PR data during validation. Native UI and live credentials need
a desktop check; mocked tests cannot establish that they work.

Publish the release after these checks, then copy the generated `pingit.rb` into
`Casks/pingit.rb` in the tap repository and commit/push it. Never publish a cask
before its public download exists. No placeholder checksum or `sha256 :no_check`
is needed. See the [Homebrew cask reference](https://docs.brew.sh/Cask-Cookbook).

Users will install with:

```sh
brew install --cask birosrichard/tap/pingit
```

Verify an actual install, launch, and uninstall on a Mac without an existing
`/Applications/pingit.app` before announcing availability. Homebrew checks:

```sh
brew style --cask birosrichard/tap/pingit
brew audit --new --cask birosrichard/tap/pingit
```

After the first release is verified, replace the pending-release notice in the
README with the install command. For updates, publish a new versioned asset and
update the cask version/checksum; users can run `brew update` and
`brew upgrade --cask birosrichard/tap/pingit`. Uninstalling removes the app but
does not revoke GitHub tokens. Users can remove tokens in Settings and revoke
them on GitHub independently. No cask `zap` rule deletes user credentials.

Listing in Homebrew's official collection is a separate contribution, subject to
its [acceptance policy](https://docs.brew.sh/Acceptable-Casks). The upstream tap
works without that approval.
