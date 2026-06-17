# GitHub PR Inbox for macOS

A native macOS menu bar app for keeping track of:

- PRs assigned to you for review
- PRs authored by you
- tracked GitHub Actions workflow failures

It is built for people who live in GitHub all day and want a compact triage surface instead of a pile of tabs.

## Features

- Native `MenuBarExtra` UI
- GitHub App device-flow sign-in stored in macOS Keychain
- Review queue, authored queue, and workflow failure queue
- CI status indicators on PR rows
- New-item markers since last open
- macOS notifications for newly detected failures
- Keyboard navigation:
  - `1` / `2` / `3` switch sections
  - `←` / `→` switch sections
  - `↑` / `↓` or `j` / `k` move selection
  - `Return` opens the highlighted row
  - `r` refreshes

## Requirements

- macOS 14+
- Xcode 16+
- A GitHub App installed on the org or account that owns the repositories you want to watch
- GitHub App permissions:
  - `Pull requests: Read`
  - `Commit statuses: Read`
  - `Checks: Read`
  - `Actions: Read`
- GitHub App configuration:
  - Device flow enabled
  - Client ID
  - App slug
- App configuration values set through Xcode build settings or environment:
  - `GITHUB_APP_CLIENT_ID`
  - `GITHUB_APP_SLUG`
  - Optional: `GITHUB_APP_EXPECTED_OWNERS` as a comma-separated list

If your org uses SAML SSO, you must also have an active SSO session for the org before authorizing the app.

## Install

### From source

```bash
open GitHubPRInbox.xcodeproj
```

Then run the `GitHubPRInbox` scheme on `My Mac`.

Before running locally, set the GitHub App values in the target build settings or export them in the shell that launches Xcode:

```bash
export GITHUB_APP_CLIENT_ID=Iv1.your_client_id
export GITHUB_APP_SLUG=your-app-slug
export GITHUB_APP_EXPECTED_OWNERS=acme
open GitHubPRInbox.xcodeproj
```

### From release

Download the latest app zip from:

- [Latest release](../../releases/latest)

Unsigned builds may require extra Gatekeeper steps. Signed and notarized releases are the preferred distribution format.

## Release Strategy

This repo supports two release modes:

1. Automatic semver tagging on merge to `main`, followed by unsigned binary zips via GitHub Releases
2. Signed and notarized release builds using a Developer ID-enabled Apple account

## Signing and Notarization

To distribute a clean-install macOS app outside the App Store, Apple requires Developer ID signing and notarization. Apple states that distributing Mac software with Developer ID requires membership in the Apple Developer Program or Apple Developer Enterprise Program and a Developer ID certificate. Apple’s current enrollment fee is listed as `$99 USD` per year for the Apple Developer Program and `$299 USD` per year for the Enterprise Program, with fee waivers available only for certain nonprofits, educational institutions, and government entities.

Relevant Apple docs:

- [Developer ID](https://developer.apple.com/support/developer-id/)
- [Program enrollment](https://developer.apple.com/help/account/membership/program-enrollment)
- [Membership fee waiver](https://developer.apple.com/support/membership-fee-waiver/)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

If you have access to a company Apple developer account, that account can be used for signing and notarization, subject to your company’s internal policy and access controls.

## Development

Run tests:

```bash
swift test
```

Build the app:

```bash
xcodebuild -project GitHubPRInbox.xcodeproj -scheme GitHubPRInbox -configuration Debug build
```

Build and install a local Release app into `/Applications`:

```bash
./scripts/install-app.sh
```

## GitHub Releases

This repo includes:

- CI validation on pushes and pull requests
- a tagged release workflow that builds a macOS app zip and publishes it to GitHub Releases

Merging a PR to `main` automatically creates the next semver tag and publishes a release:

- `major` when the PR has a `semver:major`, `release:major`, or `major` label, or the title/body includes `BREAKING CHANGE`
- `minor` when the PR has a `semver:minor`, `release:minor`, or `minor` label, or the PR title starts with `feat:`
- `patch` for everything else

You can still create a release tag manually if needed:

```bash
git tag v0.1.0
git push origin v0.1.0
```

That will also publish an unsigned release artifact. If you want signed/notarized artifacts, add the required Apple credentials and signing steps to the release workflow or run notarization locally before upload.
