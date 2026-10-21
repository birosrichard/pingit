# Phase 4A — CI checks and PR diff statistics

Implemented and validated on 2026-10-21 (Europe/Prague). Further background refresh
and notifications are outside this phase.

## Implementation and fields

Every existing compact PR row now shows PR-level changed files, additions and
deletions, plus independent current-head CI. The query uses `changedFiles`,
`additions`, `deletions`, `headRefOid`, `commits(last: 1).nodes.commit.oid`, and
`statusCheckRollup.state` with connection-wide CheckRun/StatusContext counters.
No new API requests per PR, downloaded patches, dependencies or disk cache exist.

Passing requires complete exclusively successful counters plus GitHub SUCCESS.
Real failure evidence wins over running/success; pending prevents passing;
cancelled and skipped/neutral remain distinct. Null/inaccessible rollups and
unsupported/incomplete data cannot pass. Exact failure counts require complete,
consistent counters. An authoritative complete empty connection means No checks;
a null rollup remains unavailable. **Checks passed never means Ready to merge**;
review decisions, conflicts and branch protection remain independent.

Diff metadata uses `3 files +142 −28`, semantic colors, correct singular/plural,
compact K/M notation and full integer accessibility descriptions. Missing or invalid
totals remain unavailable. Existing row links and keyboard behavior are preserved.
Rows adapt to width without a separate details screen.

Multi-token reconciliation uses newest PR snapshots and matching head SHAs only.
Available validated data can fill an inaccessible token's CI at the same snapshot.
Contradictory same-head CI retains failure/pending evidence with no exact counts;
equal-time different heads become unknown. Third observations cannot erase a
conflict. Old-head CI never fills a new snapshot. Existing per-token errors,
cancellation, generation guards and the 60-second freshness policy remain intact.
Retained CI is explicitly labelled Previous during refresh/failure.

See [the full normalization, merge and permission policy](checks.md).

## Automated validation

- **183 tests in 17 suites passed**, including all pre-existing cases. New fixtures
  cover zero/large/missing diff totals, duplicates/new heads, Checks and legacy
  statuses, failures/running/cancellation/skips/neutral, missing/future/inconsistent
  counters, field-access recovery, unrelated errors/rate limits, multi-token order
  and visibility conflicts, refresh/new-head replacement, late disconnected-session
  CI, labels/icons/full accessibility descriptions and review/CI independence.
- Full unhosted test suite uses mocked networking/in-memory credentials. No live
  token or user Keychain access is required by automated tests.
- Apple Development-signed **arm64 Debug build passed**, retaining the existing
  bundle ID, development team, provisioning and Keychain access group.
- Resolved Xcode settings: Swift 6 language mode, complete strict concurrency,
  Swift warnings as errors. Compiler invocations confirm Swift 6 and warnings as
  errors. The isolated row-render harness also compiled with explicit
  `-strict-concurrency=complete -warnings-as-errors`.
- Bundle/strict signature, sandbox, outgoing-network, private-Keychain entitlement,
  embedded-profile policy and ATS checks passed. The existing two-second launch
  smoke test passed and stopped only its temporary instance.
- Light/dark native SwiftUI ImageRenderer renders of the production row were
  visually inspected at 440 points. Synthetic data covers passing CI with Review
  required, failing CI with Approved, running, previous cancelled, large numbers,
  long titles, skipped/neutral, drafts and unavailable totals/CI. Metadata is legible
  and remains within width. Avatars use a placeholder in this isolated harness.
  This verifies row rendering, not live popover interaction or VoiceOver operation.
- Xcode emits its standard AppIntents metadata extraction notice because the app
  does not depend on AppIntents. There were no Swift compiler warnings.
- Credential-pattern scan and phase-wide Git whitespace checks passed without
  printing credential values. Unrelated untracked `artwork/website/` was excluded
  from all implementation commits. No GitHub write, push or PR creation occurred.

Reproduction:

```sh
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase4A \
  CODE_SIGN_ENTITLEMENTS=pingit/Resources/pingit-preview.entitlements \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES SDK_STAT_CACHE_ENABLE=NO test
xcodebuild -project pingit.xcodeproj -scheme pingit -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Phase4ASigned \
  SDK_STAT_CACHE_ENABLE=NO build
sh scripts/validate-app.sh build/Phase4ASigned/Build/Products/Debug/pingit.app
sh scripts/validate-launch.sh build/Phase4ASigned/Build/Products/Debug/pingit.app
```

Xcode/compiler plugins, test services, certificate trust and native rendering need
normal local macOS service access outside the restricted shell sandbox.

Build product: `build/Phase4ASigned/Build/Products/Debug/pingit.app`.
Full test result: `build/Phase4A/Logs/Test/Test-pingit-2026.10.21_16-39-48-+0200.xcresult`.
Logs: `build/phase4a-tests.log`, `build/phase4a-signed-build.log`.
Synthetic row renders: `build/phase4a-light.png`, `build/phase4a-dark.png`.
These ignored outputs contain no private CI fixtures.

## Actual read-only live validation

The existing GitHub connector and GitHub CLI authentication were used; they are
independent of the PATs saved by pingit. The connector lacks the needed exact
GraphQL rollup fields, so the CLI inspected actual GraphQL responses. No credential
was retrieved into the shell, written to a file or printed. All stored test/render
fixtures are synthetic. Live values below are public examples observed during the
run, not assertions about their later state.

| PR | Observed head CI | Validation consequence |
| --- | --- | --- |
| [pingdotgg/t3code #21678](https://github.com/pingdotgg/t3code/pull/21678) | Head `7364e143…`; 4 files, +18/−6; SUCCESS rollup; 6 successful CheckRuns, 1 skipped, 1 successful legacy status | Head/commit OIDs matched; PR totals and global counters work with `contexts(first: 1)`. Three bounded node samples identified GitHub Actions. Connector legacy-status API returned CodeRabbit success for this same SHA. App normalization is skipped/neutral, not all-passed. |
| [pingdotgg/t3code #22918](https://github.com/pingdotgg/t3code/pull/22918) | SUCCESS, 21 successful runs, 6 skipped, 2 successful legacy statuses | Successful aggregate does not erase skipped results. |
| [astral-sh/ruff #29584](https://github.com/astral-sh/ruff/pull/29584) | Head `79fa8832…`; FAILURE, 2 failing runs, 50 successful, 24 skipped | Complete global counters support 2 failing checks without fetching 76 contexts. |
| [astral-sh/ruff #29553](https://github.com/astral-sh/ruff/pull/29553) | FAILURE, 1 failing run, 51 successful, 24 skipped | Singular failure count is available. |
| [pingdotgg/t3code #22938](https://github.com/pingdotgg/t3code/pull/22938) | PENDING, 4 queued, 1 skipped | Running wins over skipped. |
| [pingdotgg/t3code #22930](https://github.com/pingdotgg/t3code/pull/22930) | FAILURE aggregate, 2 cancelled, 22 successful, 11 skipped, 1 neutral, no failure buckets | Cancelled results must not be automatically labelled genuine failures. |
| [octocat/Hello-World #1](https://github.com/octocat/Hello-World/pull/1) | Matching head/commit OIDs, null rollup | Missing rollup cannot prove CI access; app intentionally shows unavailable rather than passing or a fabricated empty list. |

GitHub search returned a SUCCESS-filtered hit whose live rollup was FAILURE because
of cancelled runs. This reinforces using the returned current-head data instead
of inferring CI from search filters. No exclusively-successful, nonempty rollup or
explicit empty non-null rollup was sampled live; deterministic fixtures cover both.
The connector's attempted personal private PR lookup returned NOT_FOUND; that
establishes only connector visibility, not whether pingit's personal PAT works.

## Permissions, remaining acceptance and next phase

PR/diff metadata needs Pull requests Read plus Metadata Read; legacy statuses need
Commit statuses Read. Checks read APIs document Checks Read, but GitHub's PAT guide
still lists Checks API access as a fine-grained PAT limitation. Documentation is
inconsistent; this implementation preserves PR/diff data and exposes unavailable
CI rather than promising that an unavailable token permission can be enabled.
See [primary sources and per-owner update steps](checks.md#token-permissions-and-current-github-limitations).
No write permissions or new authentication mechanism were added.

Private personal and Apify **app PAT scopes were not exercised** by the independent
CLI/connector session. A successful signed launch alone does not validate live
Keychain access, token permissions, selected repositories or organization approval.
Native keyboard/browser activation and interactive VoiceOver remain manual. Intel,
universal Release and older Xcode versions were not rebuilt in this phase.

Manual acceptance using the signed app, without exporting any token:

1. Run the signed build above with the normal app bundle ID and saved connections.
   In Settings verify the personal and Apify owner-labelled connections are present.
   Owner labels are informational, not proof of visibility. Adjust each PAT separately
   using the documented read-only steps; organization changes may need approval.
2. Open Review / My PRs / Drafts and compare PR totals and head SHA with GitHub for
   known visible PRs in each owner scope. Check successful, failing, running,
   cancelled/skipped and naturally unavailable/no-CI examples. A green review must
   coexist with failing CI, and passing CI with Review required. No label may say
   Ready to merge. For denied CI, verify PR/review/diff data stays visible, with
   Checks unavailable and a CI coverage explanation.
3. Press ⌘R: rows remain as Previous while loading and duplicate refresh is disabled.
   Reopen within 60 seconds without another request; reopen after 60 seconds to
   refresh. Leave idle and verify no polling. For a naturally updated PR head,
   refresh and verify old-head CI disappears even if new CI is unavailable.
4. If a scope naturally fails/offline, verify its named error and previous results,
   with other scopes retained. Restore access and refresh explicitly. Replace or
   remove a connection during refresh and verify late data cannot restore its rows.
   Removing all connections must clear private PR/CI data. Do not change GitHub PRs
   or generate failures merely for this acceptance pass.
5. Inspect all inboxes in light/dark appearance with long titles/repos and large
   diff totals. Use Tab and keyboard activation, ⌘R, Settings ⌘, and VoiceOver. Confirm
   full integer diff counts and independent CI/review descriptions are announced.
   Confirm row links still open the correct PR and only the list scrolls.

Recommended next phase: complete this signed-app two-owner/accessibility acceptance,
then decide separately whether PAT CI access justifies a future authentication
change. Comments/activity, background polling and notifications require a separate
instruction and were not started.

## Incremental implementation commits

- `3ccae5b` — PR diff statistics, query/mapping/merge and deterministic tests.
- `2041bf9` — current-head CI query, conservative normalization, optional-field recovery.
- `dd653fa` — multi-token CI reconciliation, per-source limits and late-response tests.
- `1416a6e` — compact accessible row metadata, previous-result labels and UI-model tests.
- `d37ed86` — preserve accurate CI conflict/unavailable explanations for ambiguous heads.
- Documentation follows in its own commit; see `git log` for that commit's hash.
