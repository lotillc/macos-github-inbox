# GitHub API Rate Efficiency

This follow-up reduces GitHub API fanout while preserving the inbox's
repository-level access boundary.

## Current request pattern

- Pull request search runs once for every watch scope, for both review requests
  and authored pull requests.
- A repository scope therefore creates two paginated Search API request streams.
- When tracked workflow names are configured, workflow failure checks run once
  per explicitly selected repository because the GitHub Actions API is
  repository-scoped.

## Target behavior

- Prefer one owner query (`org:` or `user:`) for a group of selected repositories
  when the complete accessible repository inventory is available; locally discard
  results outside that selected group.
- Decode and inspect Search API `total_count`. If an owner query might exceed
  GitHub Search's 1,000-result ceiling, fall back to narrower repository queries
  or safely partitioned batches so no selected pull requests are silently lost.
- Keep direct `repo:` queries for an owner whose account type or accessible
  inventory is not known, so the app never broadens a query based on a guess.
- Retain direct, explicitly selected repository requests for Actions workflow
  status. GitHub has no equivalent multi-repository Actions runs endpoint.
- Add request-count instrumentation in tests to prove that a large selected set
  under one owner produces two Search streams rather than two streams per repo,
  plus an over-cap test proving the fallback remains complete.

## Safety and limits

- Respect GitHub Search's result and pagination limits; surface an actionable
  rate-limit state instead of retrying aggressively. Treat the 1,000-result
  ceiling as a completeness condition with a narrower-query fallback, not as a
  rate-limit response.
- Preserve the existing 403/429 classification and cached-inbox behavior.
- Do not change OAuth, Keychain, SSO, installation, or notification behavior in
  this PR.
