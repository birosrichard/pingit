# Phase 6A — PR conversations and comment tracking

## Dependency and branch strategy

Inspected `origin/main` at `8211d2d` on 2026-10-22. GitHub reports PR #2
merged at 05:19:48 UTC; native notifications are present on main. This feature
branches directly from that commit in a separate worktree on
`feat/pr-comment-tracking`. No stacking, cherry-picking, changes to PR #2, or CI
infrastructure changes are needed. The original checkout remains on main.

## Design constraints

Extend the existing dashboard refresh, detector actor, atomic snapshot and native
notification coordinator. No extra timer, activity feed, team discovery or unread
counts. Fail closed on incomplete conversation coverage. Preserve Phase 5B state
while migrating its version-1 snapshot to version 2.

GitHub sources inspected before implementation:

- [GraphQL pull request fields](https://docs.github.com/en/graphql/reference/pulls)
- [GraphQL authentication](https://docs.github.com/en/graphql/guides/forming-calls-with-graphql)
- [Issue comment permissions](https://docs.github.com/en/rest/issues/comments)
- [Review comment permissions](https://docs.github.com/en/rest/pulls/comments)
- [GraphQL rate and query limits](https://docs.github.com/en/graphql/overview/rate-limits-and-query-limits-for-the-graphql-api)

Pull requests: Read-only covers review comments and is an accepted permission for
issue comments on PRs; Metadata: Read-only remains required for repository access.
No write, organization Members, or team permissions are added. Actual selected
repository visibility and organization approval cannot be inferred from an empty
search or from the token's owner label. GraphQL field denial is handled as failure,
not as an empty comment connection. No credential values were inspected.

Implementation and validation details follow in subsequent commits.
