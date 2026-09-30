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

RepoMan is a macOS app for developers managing several local Git repositories. See uncommitted changes, commits to push or pull, stale branches, linked worktrees, and missing project files in one dashboard. Build it from source, choose your repositories' parent folder, and review issues before applying fixes.

![RepoMan dashboard with illustrative data](docs/repoman-demo.png)

## Install

Requires **macOS 27 or later**, **Xcode 27**, and Git from the Xcode command line tools.

```bash
git clone https://github.com/tsilva/repoman.git
cd repoman
open RepoMan.xcodeproj
```

In Xcode, select the **RepoMan** scheme and run it on your Mac.

## Use

Click **Choose Folder…** and select the parent folder containing your repositories. Search, filter, or sort to find repositories needing attention; filter and sort controls sit beside the search field. Select a repository to see its flat **Issues needing attention** list, then select an issue to inspect evidence and available actions.

Issues include evidence and actions you can preview before applying:

- Draft an editable README or a project-specific `.gitignore`.
- Choose MIT with an explicit copyright holder, or supply custom license text.
- Select changed files and enter a message to commit their full current contents, preserving other staged files.
- Review incoming commits before a fast-forward pull, or outgoing commits before a regular push to the configured upstream branch.
- Ignore a check for one repository, or disable it globally from **Enabled checks** in the toolbar's overflow menu.

File creation leaves files untracked; committing and pushing are separate actions. README drafts are starter templates to edit. Conflicts, staged renames, and diverged histories require review in your Git editor. If a repository changes after a preview, prepare a new preview before applying it.

See [the detector and action architecture](docs/issues.md) for adding checks and fixers.

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
- RepoMan remembers your folder, selected repository, ignored checks, and disabled checks between launches.
- Local status refreshes every two minutes. Repositories with an upstream fetch after the initial scan and every ten minutes. **Refresh** checks the selected repository; **Refresh All** checks all repositories.
- Refresh fetches remote-tracking refs without merging, pulling, pushing, or changing working files. Git commands have timeouts and disable credential prompts. Failed fetches keep local status visible, but remote counts may be outdated.
- Only an explicitly applied issue action changes working files, commits, or remote branches. Pull and push previews fetch fresh remote refs; pushes never force and pulls require a clean working tree.
- Push/pull findings require a known upstream comparison. Stale branches have no commits in 90 days, excluding `main`, `master`, and branches checked out in any worktree. Linked worktrees exclude the primary worktree and appear as informational findings.
- The screenshot and `--demo` mode use illustrative data. Demo mode permits previews but cannot apply actions.
- Local packaging writes a DMG and checksum under `dist/`. Pushing a `vX.Y.Z` tag publishes them through the [release workflow](.github/workflows/release.yml). Packaged builds are signed ad hoc and are not notarized; Gatekeeper may require manual approval.
- No license is declared in this repository.

## Architecture

The diagram shows discovery and refresh. The [checks and actions guide](docs/issues.md) explains issue detection, previews, and explicitly applied fixes.

![RepoMan refresh architecture: folder discovery, refresh coordination, Git scanning, and the dashboard](docs/architecture.png)
