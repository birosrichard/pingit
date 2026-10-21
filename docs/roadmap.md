# Development roadmap

Phases 1, 2, 3A, 3B, 3C and 3D are implemented. Phases 4–8 remain planned.
Keep each phase independently buildable and validate before moving on.

## 1. Project foundation

- Native Swift 6 / SwiftUI Xcode app targeting macOS 14+, with strict concurrency.
- MenuBarExtra popover, disconnected state, inactive Refresh, Settings, and Quit.
- Native Settings scene with connection status and bundle version/build.
- No persistent Dock icon, dependencies, network access, or persistence.
- Acceptance: build succeeds; validate the signed bundle and manually verify
  launch, Settings reopening, light/dark appearance, and clean quit.

## 2. GitHub authentication — implemented

- Single GitHub.com account using a personal access token and authenticated `GET /user`.
- Secure Settings input, username/avatar, shared menu bar status, and disconnect.
- No additional fine-grained permissions; no write/private repository access requested.
- Provisioned app-specific Data Protection Keychain storage, startup restoration,
  explicit retry, sanitized failures, and deletion on disconnect/invalid saved token.
- Outbound sandbox networking; no file/server/temporary entitlements or ATS overrides.
- Mocked client/Keychain/lifecycle tests; Debug and universal Release validation.
- Real Keychain and visual acceptance require a development-team-signed app and
  the manual checklist in README. Ad hoc builds support UI inspection/mocked tests.
- No PR fetching, review tracking, OAuth, polling, or notifications in this phase.

## 3. GitHub data access and pull requests

### 3A. GraphQL foundation — implemented

- Reuse the authenticated URLSession client for typed GraphQL requests/variables.
- Explicit HTTP, query, partial/missing-data, rate-limit, decoding, and cancellation failures.
- Independent repository, PR, review/check status, and user/team review-request values.
- Deterministic mocked tests; no live PR queries, aggregation, or UI changes.

### 3B. Pull request discovery — implemented

- Authored open PR search including drafts; direct active review requests excluding drafts/own PRs.
- Strict transport mapping, creation/update timestamps and stable node identity.
- Bounded cursor pagination, deduplication, recent ordering and explicit truncation.
- Token visibility is always limited; team discovery is explicitly excluded.
- Mocked tests cover discovery, failures and cancellation; no UI or lifecycle calls yet.
- See [discovery permissions and limitations](discovery.md). Live token coverage remains unverified.

### 3C. Pull request review status — implemented

- GitHub's authoritative overall decision, including explicit unknown values.
- Bounded latest non-pending reviews per user, preserving dismissed/commented states.
- Per-PR limitations for truncated, unavailable, missing or unsupported details.
- Review fields batched into both discovery queries; no full histories or N+1 requests.
- Mocked tests and arm64 Debug build pass; signed Keychain/live API remain unverified.
- See [review semantics and limitations](reviews.md). No CI, UI, polling or notifications.

### 3D. Live pull request dashboard — implemented

- Native scrolling authored/direct-review lists, counts, drafts, overall review decisions, and validated browser links.
- Separate observable section states, cached results, timestamps, and coverage/truncation notes.
- On-open loading with 60-second freshness, explicit Refresh, duplicate prevention, and no timers.
- Successful disconnect cancels and clears; session guards reject stale responses after reconnect.
- All 104 mocked tests and signed arm64 Debug build pass. User-supplied live screenshot
  confirms authored results and empty direct requests; full visibility/nonempty live direct
  requests and UI interaction/accessibility still need the acceptance checklist.
- See [dashboard behavior and validation](dashboard.md). No CI, polling, notifications, or GitHub writes.

## 4. Reviews and relevant activity

- Show approvals, requested changes, comments, mentions, and relevant activity.
- Acceptance: items link to the correct GitHub destination, show their source and
  time, and avoid duplicate or unrelated activity. No fabricated activity.

## 5. CI and checks

- Add check status for tracked PRs, including pending, success, and failure.
- Acceptance: multiple checks and missing data are represented accurately;
  transitions and links to failed checks are verified against real GitHub data.

## 6. Background updates and native notifications

- Add cancellable, rate-aware polling and opt-in macOS notifications.
- Acceptance: only meaningful new events notify; repeated polls do not duplicate
  alerts; sleep/wake, offline recovery, permission denial, and quit behave cleanly.

## 7. Preferences and reliability

- Add repository selection and notification preferences with persistence.
- Acceptance: choices survive restart and apply to filtering/alerts; credential
  boundaries remain intact; error recovery, accessibility, and resource usage
  are tested with representative workloads. No unnecessary idle work.

## 8. Distribution and release readiness

- Prepare GitHub Releases, Homebrew, and Mac App Store distribution.
- Choose an open-source license; add release assets, signing/notarization,
  reproducible release checks, and required privacy/store metadata.
- Acceptance: clean machines can install, launch, upgrade, and uninstall supported
  builds; Developer ID and sandboxed App Store paths are validated independently.
