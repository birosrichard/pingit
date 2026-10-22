# macOS build and test CI

[`macOS CI`](../.github/workflows/macos.yml) runs for pull requests targeting
`main` (the repository's default branch), including drafts, and for manual
`workflow_dispatch` runs. If the default branch is renamed, update the branch
filter. Manual dispatch becomes available in GitHub's Actions UI once the workflow
exists on the default branch.

## Toolchain and scope

One GitHub-hosted `macos-15` job selects **Xcode 26.3, build 17C529**, explicitly via
`DEVELOPER_DIR=/Applications/Xcode_26.3.app/Contents/Developer`. This combination
is listed in GitHub's [macOS 15 arm64 runner image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md)
(checked 2026-10-21). The OS label is pinned rather than using `macos-latest`;
GitHub still updates the underlying image. The script prints installed Xcodes,
checks the selected executable and, in GitHub Actions, exact Xcode version/build.
It fails clearly if the required toolchain is missing or different, and records
macOS, architecture, Swift compiler
location/version and installed SDKs. Toolchain upgrades must update the workflow,
script and this document together after checking the manifest and a macOS run.

[`scripts/ci-macos.sh`](../scripts/ci-macos.sh) runs one `xcodebuild test` action
against `pingit.xcodeproj`, the shared `pingit` scheme, and Debug configuration.
The scheme builds `pingit.app` for testing and runs the entire unhosted
`pingitTests` Swift Testing target, which compiles the shared application logic
without launching the menu bar app. No test filters are applied. Tests use mocked
networking and injected Security operations, with no live GitHub tokens or real
Keychain access. There are no external package dependencies to restore.

The app and tests retain their macOS **14.0** deployment target and enforce
`SWIFT_VERSION=6.0`, `SWIFT_STRICT_CONCURRENCY=complete`, and
`SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`. CI also sets
`GCC_TREAT_WARNINGS_AS_ERRORS=YES` for C-family compilation where applicable.
These match or strengthen existing compiler policy. Xcode tool notices such as
AppIntents metadata extraction are outside compiler warning enforcement.

The destination uses the runner's native architecture (`uname -m`). GitHub's
[standard runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
currently maps `macos-15` to a 3-core M1 arm64 runner, available to private
repositories on GitHub Free. This initial job validates Debug on one host, not a
universal Release app or execution on macOS 14. There is no matrix, separate
duplicate build, clean action, dependency installation, or shared cache. A
15-minute job limit bounds stalled builds. Concurrency uses the source repository
and branch so new runs cancel superseded runs for the same PR, and manual runs
on that same branch share the cancellation group. There is no `push` or scheduled
trigger and no other build workflow, avoiding duplicate push/PR runs per commit.

## Private repository allowance and estimated consumption

This repository is private on GitHub Free. Standard `macos-15` uses the included
Actions allowance; it does not require a paid plan or larger/premium runners.
GitHub Free currently includes **2,000 Actions minutes per month** and **500 MB
artifact storage**, shared with the owner's other applicable usage. See
[included usage](https://docs.github.com/en/billing/reference/product-usage-included)
and [Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions).
The workflow works while sufficient allowance remains; it does not change payment
methods, budgets, or spending limits, and cannot guarantee free execution after
that allowance is exhausted.

Budget **5–10 runner minutes per run** initially, including checkout, toolchain
checks, compilation, tests and diagnostics upload. This is an unmeasured estimate
until the first macOS run. GitHub rounds each job up to a whole minute; the
15-minute timeout bounds normal execution to roughly **15 runner minutes**,
with cancellation/cleanup overhead potentially adding time. Failed, cancelled,
manual and rerun jobs also consume the time they execute. Use the owner's actual
usage report to confirm included-allowance deductions; do not assume macOS and
Linux allowance accounting are interchangeable. For conservative planning,
reserve **50–100 allowance-minute equivalents** per estimated run (a 10× budgeting
factor), or **150** at timeout; this is a planning reserve, not a measured charge.

GitHub currently lists the same **$0.062 USD per runner minute** for standard M1
and Intel macOS, the cheapest hosted macOS tier. At that rate, a 5–10 minute run
has a list-price equivalent of **$0.31–$0.62**, or **$0.93** for 15 minutes, if
chargeable beyond the included allowance. These figures are calculated from the
[runner pricing reference](https://docs.github.com/en/billing/reference/actions-runner-pricing)
(checked 2026-10-21), not a request to enable paid usage. Actual duration and
account usage must be checked before estimating how many monthly runs fit.

Only logs and test results are uploaded, with **one-day retention**, to reduce
storage consumption; DerivedData and built products are excluded. Console logs
remain available in Actions without artifact storage charges. Avoid manually
dispatching a run for a commit already being checked by its PR unless a rerun
is needed. There is no automatic retry or extra job to spend more minutes.

## Logs and failures

Raw build and test output appears in the job console and in
`build/ci/run.*/ci.log`. The same directory holds `TestResults.xcresult`, which
can be downloaded and opened in Xcode for detailed failures. The diagnostics
artifact is uploaded on success or failure when files exist, retained for one
day, and excludes DerivedData and app products. Early toolchain/build failures
may produce only a log, without a complete result bundle; forced cancellation
may prevent upload.

The shell uses `set -euo pipefail`; logging through `tee` preserves nonzero
`xcodebuild` statuses. Compile errors, compiler warnings, failing tests, and
toolchain mismatches fail CI. There are no retries or ignored test failures.

## Reproduce locally

On macOS, install full Xcode, complete its first-launch setup, then run from the
repository checkout using your selected Xcode (including Xcode 27.1):

```sh
bash scripts/ci-macos.sh
```

The script uses `DEVELOPER_DIR` when set, otherwise `xcode-select -p`. If your
selection points to Command Line Tools or a different Xcode, select the app for
this shell:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/ci-macos.sh
```

Local runs report the version without enforcing the hosted CI pin. To reproduce
the hosted toolchain exactly, use Xcode 26.3 (17C529). Each invocation
creates a fresh diagnostics directory and reuses ignored
`build/ci/DerivedData`. The script contains the exact `xcodebuild` command used
in Actions. No developer account or signing identity is needed for this check.

## Signing and security boundaries

The existing app Debug/Release settings use automatic signing, a committed
development team ID, and `pingit/Resources/pingit.entitlements` with a restricted
Keychain access group. The team ID is not a credential and is insufficient to
sign on a fresh hosted runner. A normal development build requires that team's
certificate/private key and a suitable provisioning profile; CI does not use it.

Instead, CI applies invocation-only Debug overrides: manual **ad hoc signing**
(`CODE_SIGN_IDENTITY=-`, `CODE_SIGNING_ALLOWED=YES`), empty team/profile settings,
and the existing `pingit-preview.entitlements`. This retains App Sandbox and
outbound networking while omitting the restricted Keychain group. Project settings
and normal local signing remain unchanged. Hardened runtime remains configured;
Xcode disables it for ad hoc builds, as in the existing preview workflow.

Passing CI proves compilation and mocked tests, not provisioned Keychain access,
signed credential migration, live GitHub integration, visual/accessibility behavior,
or launch-time policy acceptance. `validate-app.sh` expects an ordinary build
product; Xcode's test action injects extra test entitlements, so that script is
not run against CI's test product. `validate-launch.sh` needs a logged-in desktop
session and remains a separate local smoke check. Distribution, Developer ID
signing, notarization, and universal Release validation remain separate work;
this ad hoc test product is not a distributable signed app. Follow the
[README validation commands](../README.md#validation) for local product checks.

The workflow uses `pull_request`, never `pull_request_target`, with only
`contents: read`. It references no secrets, certificates, profiles, Apple accounts,
or live API credentials. Checkout does not persist its token for PR code. The only
actions are official GitHub checkout/upload-artifact actions pinned to immutable
commit SHAs. Test code runs on a disposable hosted runner without privileged
repository or signing credentials; diagnostics are untrusted PR-generated output.

## Linux development

Linux cannot run Xcode, SwiftUI/AppKit/Security builds, macOS code signing, or this
macOS test bundle. A Linux Swift compiler alone cannot replace the macOS check.
Linux validation can parse YAML, lint GitHub Actions syntax with `actionlint`,
check `bash -n scripts/ci-macos.sh` (and ShellCheck when available), verify shared
scheme/target/resource paths, run `git diff --check`, and scan changed text for
credential patterns. These checks do not establish that the app compiled or its
tests passed; the first successful hosted macOS run must establish that evidence.
