# RepoMan

<img src="logo.png" alt="RepoMan logo" width="280">

RepoMan is a native macOS 27 app for monitoring Git checkouts that share a parent folder. Select a folder once, then use the sidebar to compare repositories and the detail pane to inspect a selected checkout.

![RepoMan demo](docs/repoman-demo.png)

## Run

Open `RepoMan.xcodeproj` in Xcode 27 and run the **RepoMan** scheme on macOS 27 or later. Choose the parent folder containing your repositories. RepoMan remembers that folder and the selected repository between launches.

The app discovers direct child folders with a `.git` directory or file. It shows the current branch, commits ahead of and behind its configured upstream, changed files, stale local branches, and linked worktrees. The detail pane shows recent commits and per-file added and removed line counts.

## Refresh behavior

RepoMan scans local status when you choose a folder and every two minutes while open. It fetches configured upstream remotes after the initial scan and every ten minutes, using at most four concurrent Git tasks. Refreshing updates remote-tracking refs; RepoMan does not merge, pull, push, or modify working files. The refresh button checks the selected repository, and **Refresh All** is available from the toolbar menu or **Repositories** menu.

An absent upstream is shown as a dash in the push and pull cards. A remote failure leaves local status visible and reports that the remote is unavailable. Stale branches are local branches whose last commit is at least 90 days old, excluding `main`, `master`, the current branch, and branches checked out in linked worktrees. The worktree count excludes the primary worktree.

## Development

Run `swift test` for the Git scanner integration tests. Launch the app with `--demo` to show illustrative data for design review. The screenshot above contains illustrative counts and line changes.

## GitHub releases

After committing and pushing the project, push a version tag in the form `vX.Y.Z` (for example, `v0.1.0`). The [release workflow](.github/workflows/release.yml) runs the same [build-release helper](.codex/skills/build-release/scripts/build-release.sh) used locally: it tests, builds an arm64 macOS app, signs it ad hoc, creates and verifies a compressed DMG containing `RepoMan.app` and an Applications shortcut, and publishes the DMG and its SHA-256 checksum as a GitHub Release. The workflow uses GitHub's `xcode-27` Apple Silicon runner, so these builds require macOS 27 or later on Apple Silicon.

```sh
git tag -a v0.1.0 -m "RepoMan v0.1.0"
git push origin v0.1.0
```

To build and package locally without publishing, invoke `/build-release` or run `bash .codex/skills/build-release/scripts/build-release.sh`. The helper prints the DMG and checksum paths under `dist/`.

Release builds have an ad-hoc signature, but no Developer ID signature or Apple notarization. macOS Gatekeeper may require manual approval before opening the downloaded app. Add Developer ID signing and notarization before using this workflow for a frictionless public distribution.
