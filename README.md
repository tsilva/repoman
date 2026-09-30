<p align="center">
  <img src="logo.png" alt="RepoMan logo" width="280" />
  <br />
  <!-- repo-tagline:start -->
  <strong>🔭 Keep your Git repositories in sight 📂</strong>
  <!-- repo-tagline:end -->
</p>

<p align="center">
  <a href="https://github.com/tsilva/repoman/blob/main/RepoMan.xcodeproj/project.pbxproj"><img src="https://img.shields.io/badge/macOS-27%2B-blue" alt="Requires macOS 27 or newer" /></a>
</p>

RepoMan is a macOS app for developers who want to keep track of several local Git repositories. One dashboard shows uncommitted changes, commits to push or pull, stale branches, and linked worktrees. Build it from source and choose the folder containing your repositories to get started.

![RepoMan dashboard with illustrative data](docs/repoman-demo.png)

## Install

Requires **macOS 27 or later**, **Xcode 27**, and Git from the Xcode command line tools.

```bash
git clone https://github.com/tsilva/repoman.git
cd repoman
open RepoMan.xcodeproj
```

In Xcode, select the **RepoMan** scheme and run it on your Mac. Click **Choose Folder…** in the app and select the parent folder containing your repositories.

Search, filter, or sort to find repositories needing attention. Select one to inspect recent commits and file changes. RepoMan remembers your folder and selection between launches.

## Commands

```bash
swift test  # run core and Git integration tests

# Build the app locally
xcodebuild -project RepoMan.xcodeproj -scheme RepoMan \
  -configuration Debug -derivedDataPath DerivedData build

# Show illustrative data for design review
open DerivedData/Build/Products/Debug/RepoMan.app --args --demo

# Test and package an Apple Silicon DMG with a SHA-256 checksum
bash .codex/skills/build-release/scripts/build-release.sh
```

## Notes

- Discovery scans visible direct child folders with a `.git` directory or file, including linked worktrees. Nested folders are not scanned.
- Local status refreshes every two minutes. Repositories with an upstream fetch after the initial scan and every ten minutes. **Refresh** checks the selected repository; **Refresh All** checks all repositories.
- Refresh fetches remote-tracking refs without merging, pulling, pushing, or changing working files. Git commands have timeouts and disable credential prompts. Failed fetches keep local status visible, but remote counts may be outdated.
- Push/pull counts show a dash without an upstream. Stale branches have no commits in 90 days, excluding `main`, `master`, and branches checked out in any worktree. Worktree counts exclude the primary worktree.
- The screenshot and `--demo` mode use illustrative data.
- Local packaging writes a DMG and checksum under `dist/`. Pushing a `vX.Y.Z` tag publishes them through the [release workflow](.github/workflows/release.yml). Packaged builds are signed ad hoc and are not notarized; Gatekeeper may require manual approval.

## Architecture

![RepoMan architecture: folder discovery, refresh coordination, Git scanning, and the dashboard](docs/architecture.png)

## License

No license is declared in this repository.
