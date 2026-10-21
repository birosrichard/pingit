> Phase 4A adds independent current-head CI and PR diff totals to the existing
> discovery/refresh lifecycle. See [CI semantics and token limitations](checks.md)
> and [Phase 4A validation](phase-4a.md). Historical validation below remains unchanged.

# Multiple fine-grained GitHub tokens (Phase 3E)

pingit supports one GitHub.com identity with independent token scopes, for example
`birosrichard` and `apify`. The authenticated user is distinct from a fine-grained
PAT's resource owner. `/user` supplies user ID/login; the owner is an explicitly
unverified user-configured label. A successful login or empty search cannot establish
private repository access, selected repository coverage, or organization approval.
Use Pull requests: Read-only and accompanying Metadata: Read-only for private PRs.
No GitHub mutations or additional write permissions are used.

## Storage and migration

Production stores non-secret metadata in sandboxed UserDefaults under
`github.connections.v1`: connection UUID, credential-reference UUID, validated
account/HTTPS avatar URL, owner label, status/date, migration UUID/completion, and
pending credential deletion references. It stores no token values or PR content.
Tests use in-memory metadata or unique isolated preferences suites.

Tokens remain in the same `<bundle-id>.github` Data Protection Keychain service,
private access group and signing configuration. Each new item has account
`connection-<UUID>`, synchronization disabled, and
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. UUIDs do not depend on token contents.
The local connection ID survives replacement; replacements use a fresh credential
UUID so they cannot overwrite the old token before validation/storage succeeds.

The old account `personal-access-token` migrates automatically:

1. Read metadata. If migration is complete, do not import a legacy item again.
2. Read the old token. Missing means no migration is needed; inaccessible means
   failure/retry, rather than an empty successful migration.
3. Persist a randomly generated migration UUID before writing its new Keychain item.
4. Read the destination. If absent, copy the token. Read it back and compare in
   memory. A different existing value is a collision/error; neither item is deleted.
5. Persist the destination connection reference. Metadata writes synchronize and
   verify the saved bytes before migration is allowed to delete the old token.
6. Delete the legacy entry only after the secure read-back and metadata checks.
   Mark migration complete. No token re-entry is required for a valid old credential.
7. Validate the copied token through `/user`. Failed validation retains the credential
   and an actionable status for replacement/removal. If only legacy deletion failed,
   the verified replacement can still authenticate while cleanup remains retryable.

An interruption before copying retries with the same UUID. An interruption after
copying or after metadata persistence finds/reuses that verified destination. An
interruption after legacy deletion retains the already saved connection and completes
the ledger on retry. Read/write/delete failures preserve credentials needed for
recovery. Corrupt/contradictory metadata is reported rather than silently reset;
duplicate references and deletion of an active reference are rejected.

Adding validates before secure storage and rejects another identity (numeric user ID
when both available, otherwise case-insensitive login). Owner labels compare without
case, with surrounding whitespace trimmed. Duplicate token values are compared only
in memory. A migrated credential with no known identity must validate before another
connection is added; it can instead be explicitly replaced or removed if invalid.

Replacement writes and verifies a new Keychain item, then persists the new reference
and old-item cleanup intent before deleting the old item. If metadata persistence
reports an ambiguous failure after writing, both credentials are retained so restart
can recover whichever reference was persisted. A process interruption before saving
any reference can leave an unused new Keychain item; it does not overwrite the prior
credential. There is no broad service-wide cleanup that might delete another token.

Removal persists deletion intent before deleting just the selected credential. A
reported deletion failure restores the prior metadata/UI for retry; an interrupted
removal is completed from its ledger at launch. Old credential cleanup failures are
visible and retried through Retry saved connections. Removing a local token does not
revoke it on GitHub. Downgrading to the single-token version is not supported.

## Discovery, merging and lifecycle

The dashboard loads each configured credential once per refresh, outside observable
state. A task group runs at most two connection workers, each querying authored PRs
and active direct review requests concurrently (four searches in flight at most).
Every page receives its own token explicitly; the client has no mutable/global
credential or rate-limit state. Existing per-query 200-result defaults, 20-page and
1,000-hit bounds remain unchanged. No automatic aggressive retries are added.

Each connection/section retains its own result, pagination/coverage limitations,
last-success timestamp, loading state and sanitized error. Invalid/revoked tokens,
403 access denial, network errors, rate limits, and GraphQL partial/missing results
fail that source independently. The dashboard names failed owner labels; it retains
that source's prior results as stale and still publishes successful sources. It does
not convert failed scopes to successful empty searches. A denied response is confirmed;
permissions, pending approval and organization policy are possible explanations,
not diagnoses made from an empty search.

Authored and direct-review sections are merged separately by PR node ID. The same PR
may legitimately appear in both sections. Sorting is descending update date, then
node ID for deterministic ties, independent of task completion order. Merge policy:

- Use the most recently updated observation for ordinary snapshot fields. At equal
  timestamps, configured source order provides a deterministic tie.
- Fill missing author/review/request metadata from another observation only for the
  same update timestamp. A newer unknown decision never inherits an older approval.
- An authoritative known decision can fill an unknown decision at the same timestamp.
  Contradictory known decisions become unknown and add a coverage warning. Once a
  conflict is found, a third agreeing token cannot erase it during that merge.
- Available reviewer details can replace unavailable details. A complete list can
  replace an incomplete compatible subset. Contradictory details are withheld and
  warned about; individual reviews never calculate the overall decision. Compatible
  incomplete same-snapshot lists now union their review IDs and limitation flags,
  retaining useful activity without implying completeness (Phase 3F).
- Contradictory complete request lists are withheld with a warning. Equal-timestamp
  draft disagreement is warned about and displayed conservatively as draft.
- Union pagination and coverage reasons. Each source retains its original metadata,
  so the merged list does not imply that any owner was completely searched.

Refresh retains loaded rows and timestamps and rejects duplicate refreshes. The
60-second freshness policy still applies on opening, without timers or polling.
Adding/replacing/removing invalidates the active generation, cancels its task/children,
and refreshes the updated set. Removal recomputes the union immediately using only
remaining sources; replacement discards only the replaced source's cache. Generation
checks reject late responses even from cancellation-insensitive operations. A full
disconnect clears all rows. First connection/restoration waits for the popover unless
it has already requested data; subsequent connection changes refresh immediately.
No private PR content is persisted across launches.

## Validation on 2026-10-21

- Full suite: **137 tests across 10 suites**, including all 104 original cases.
  Prior single-item read-count/expired-token assertions now reflect secure migration
  and retention for explicit replacement. No live credentials or user Keychain calls.
- Deterministic coverage includes same/different identities, invalid/duplicate tokens,
  replacements/removal, restart metadata, failed/ambiguous persistence, interrupted
  migration stages, Keychain verification/read/write/delete failures, collision safety,
  independent errors/rate limits, real per-token HTTP Authorization contexts, overlapping
  node IDs/review conflicts, coverage, freshness, bounded workers, and late responses
  after removal/replacement/disconnect. UI model states and accessibility identifiers
  are covered; visual/VoiceOver behavior requires manual acceptance.
- Development-signed arm64 Debug build uses Swift 6 language mode, complete strict
  concurrency, and Swift warnings as errors. Bundle/signature/sandbox/network/private
  Keychain entitlement checks run against the ordinary build product. Xcode's standard
  AppIntents extraction notice is unrelated to Swift compiler warnings.
- Credential-pattern and diff whitespace checks run without printing any credentials.
  The existing Xcode project formatting/signing modifications remain uncommitted and
  unchanged. No new dependencies, backend, GitHub writes, push or pull request.
- Live migration and two real PAT scopes have not been exercised in this pass.
  Computer Use was not approved to access pingit, blocking interactive validation.
  No credentials were retrieved from Keychain into tools/files. Organization approval,
  actual repository coverage, launch/UI behavior, keyboard/VoiceOver and Intel/Release
  acceptance remain manual. The signed build alone does not verify live Keychain use.

## Manual acceptance

1. Quit the existing pingit instance. Build/run the normal development-signed app from
   Xcode, or open `build/Phase3ESigned/Build/Products/Debug/pingit.app`. Keep the original
   bundle ID, signing team and Keychain group. Do not copy any token to a shell or chat.
2. For an existing single-token installation, verify Settings shows a **Legacy token**
   connection and the same authenticated username without token re-entry. Open the
   popover and compare known personal PRs with GitHub. Restart and verify restoration.
   If Keychain is locked/unavailable, unlock and use Retry saved connections.
3. In Settings, choose Add GitHub token. Enter owner label `apify` and use the secure
   field for a fine-grained PAT created with that resource owner and the required
   repository read access. Verify validation progress, cleared token entry, the same
   authenticated username, two independent rows and owner-unverified status. The old
   label can be changed when replacing its token; owner labels do not filter searches.
4. Confirm another GitHub identity is rejected without changing either saved row.
   Confirm case-insensitive duplicate owner labels and reusing the same token are
   rejected. An invalid token should show a sanitized error and save no new connection.
5. Open/Refresh the dashboard. Compare authored results with GitHub's
   `is:pr is:open author:YOUR_LOGIN`, and direct requests with
   `is:pr is:open user-review-requested:@me -author:YOUR_LOGIN draft:false`.
   Compare only repositories selected/visible to these PATs. Personal PRs must remain;
   organization PRs appear only when repository access and approval permit them.
   Check a known overlap appears once per section, plus drafts, decisions, counts,
   timestamps, browser links, neutral token coverage information, and visible
   warnings for actual failures.
6. If an organization token is pending/denied, confirm the UI does not claim private
   access. An explicit error must name the scope and leave personal results visible.
   Empty organization results alone cannot verify access. Use an existing known
   permission failure; do not broaden permissions or exhaust rate limits for testing.
7. Refresh while loaded: prior rows stay visible, duplicate refresh is disabled, and
   partial/offline failures retain stale results with an error. Reopen within 60 seconds
   without another request; reopen after the threshold to refresh. Restore networking
   and retry explicitly. Leave the app idle and confirm no polling.
8. Remove one token during refresh and confirm the dialog. Its exclusive PRs must
   disappear immediately, shared PRs remain through the other source, and late results
   cannot restore removed rows. Refresh the remaining scope; restart and verify it
   still works. Canceling removal should change nothing.
9. Replace a token during refresh. Failed validation must preserve its old token/data;
   successful replacement must retain the row's local ID, discard that source's old
   cached results, and refresh. Restart with both configured tokens to confirm both
   persist. Remove all rows and verify disconnected state remains after restart.
10. Check empty/multiple Settings rows, keyboard focus and secure field, progress/error
    announcements in VoiceOver, named Replace/Remove controls, confirmation, scroll,
    long labels, light/dark mode, PR Link activation, Settings ⌘, and Refresh ⌘R.
