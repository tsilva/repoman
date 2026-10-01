<p align="center">
  <img src="logo.png" alt="RepoMan logo" width="280" />
  <br />
  <!-- repo-tagline:start -->
  <strong>🔎 Find issues across your Git repositories. Fix them with AI. 🤖</strong>
  <!-- repo-tagline:end -->
</p>

<p align="center">
  <a href="https://github.com/tsilva/repoman/blob/main/RepoMan.xcodeproj/project.pbxproj"><img src="https://img.shields.io/badge/macOS-27%2B-blue" alt="Requires macOS 27 or newer" /></a>
</p>

RepoMan is a macOS app for developers managing several local Git repositories. See uncommitted changes, commits to push or pull, stale branches, linked worktrees, missing project files, failing CI, and missing CI coverage in one dashboard. Build it from source, choose your repositories' parent folder, and repair issues through a Codex conversation for each issue.

![RepoMan app showing repositories, detected issues, and repair instructions with illustrative data](docs/repoman-demo.png)

## Install

Requires **macOS 27 or later**, **Xcode 27**, and Git from the Xcode command line tools.

```bash
git clone https://github.com/tsilva/repoman.git
cd repoman
open RepoMan.xcodeproj
```

In Xcode, select the **RepoMan** scheme and run it on your Mac.

## Use

Click **Choose Folder…** and select the parent folder containing your repositories. Search, filter, or sort to find repositories needing attention; filter and sort controls sit beside the search field. Select a repository to see its flat **Issues** list, then select an issue to inspect evidence and choose repair instructions. The folder and terminal buttons in the toolbar open the selected repository in Finder or Terminal.

Choose a repair preset or write custom instructions, edit the prompt, then click the **send button** at the bottom right of the textarea, or press **⌘Return**. Every repair uses the same agent workflow, including commits, push/pull, missing files, divergence, and worktree or branch cleanup. Selecting a preset does not run it.

Each issue has one conversation. The send button inside the composer (or ⌘Return) sends the draft to Codex; submitted messages become read-only chat bubbles. The composer stays below the stream, and presets help compose the first prompt and disappear once it is sent. Assistant messages use Markdown, and shell commands expand to show their output. Animated thinking and working indicators show progress while waiting for Codex. Answer questions in the stream or stop the current turn from the composer.

After every turn, RepoMan checks the issue again. If it remains or verification is unavailable, send another message in the same Codex thread. Conversations survive switching issues and restarting the app. Different issues can run at the same time, including in the same repository; each chat has its own Codex connection. Confirmed resolution keeps the issue in the list with a Finished state. Its conversation remains selectable and readable, with its composer removed. Finished issues keep their complete conversations across restarts and do not count toward outstanding issues. Repairs run without approval prompts inside the selected repository; sandboxed commands cannot read or write other personal files or repositories.

![RepoMan live repair conversation with illustrative data](docs/repoman-repair.png)

Install and sign in to the **Codex CLI** before running repairs. RepoMan automatically finds Codex and starts `codex app-server` over stdio. Every turn uses **GPT-6.1 Sol** (`gpt-6.1-sol`) with **high** reasoning effort, repository-scoped permissions, and approvals disabled. Authentication remains managed by Codex; RepoMan does not copy its credentials.

After each turn ends, RepoMan collects fresh repository state and reruns the original detector. The issue disappears only when inspection confirms it is absent. An agent finishing successfully can still leave the issue present; failed inspection produces **Couldn’t verify**. Creating a README can resolve that issue while introducing an uncommitted-change finding.

Open **Settings…** from the toolbar's overflow menu or press **⌘,** to enable or disable issue checks globally. Settings groups checks by Git, repository files, CI, and inspection, and saves changes automatically. Search settings to find a check, or use **General** to change the monitored folder. These display preferences do not cancel tasks or count as successful repairs.

**CI failing** reads GitHub check runs and commit statuses for the latest published default-branch commit and the tracked branch (or matching published local branch). Install the GitHub CLI and sign in with `gh auth login`; RepoMan finds `gh` automatically and uses its existing login. Failed checks include a link to CI details. Pending, cancelled, missing, inaccessible, or incomplete results stay unavailable and cannot confirm a repair. Local unpushed changes are not represented by remote CI results.

**Missing CI coverage** inspects local GitHub Actions workflows in code projects for recognizable build, test, lint, or type-check commands on branch pushes or pull requests. Dependency review, manual workflows, and tag-only releases do not satisfy it. This is a conservative configuration check, not a measurement of test coverage: custom actions, unrecognized scripts, reusable workflows, unsupported YAML, and external CI configurations may require review and are reported as unavailable.

Additional checks cover dependency safeguards, lockfile and runtime consistency, Actions security, unpublished branches and upstream tracking, potential tracked secrets, oversized files, submodule/LFS checkout integrity, leftover merge markers, broken project and documentation references, tracked generated files, old stashes, unfinished Git operations, published description drift, and opt-in notebook hygiene. See [additional checks and per-repository exceptions](docs/additional-checks.md) for `.repoman.json` configuration.

See [the detector, recipe, and task architecture](docs/issues.md) for extending the workflow.

## Commands

In Codex, `$build-release` or `/build-release` builds, verifies, and publishes a
GitHub Release. Request a local build explicitly to keep the artifacts local.
The shell helper below builds local artifacts without publishing.

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

- Discovery scans visible direct child repositories with a `.git` directory or file. Linked worktrees are excluded from the repository list and shown under their primary repository. Nested folders are not scanned.
- RepoMan remembers your folder, selected repository, filter, sort mode and direction, ignored checks, and disabled checks. Issues and their conversations persist under `~/Library/Application Support/RepoMan/repair-tasks.json`; interrupted sessions are reconciled without automatically replaying their prompts.
- While a repository is being checked, a spinner replaces its issue counter. Each repository returns to its issue count as soon as its check finishes.
- RepoMan automatically checks all repositories once at startup, fetching configured remotes even without an upstream and pruning deleted remote-tracking branches. Checks do not repeat on a timer. Choosing a folder checks its repositories; **Refresh** checks the selected repository and **Refresh All** explicitly checks all repositories. Repairs verify the affected repository when work stops.
- Refresh fetches remote-tracking refs without merging, pulling, pushing, or changing working files. Git commands have timeouts and disable credential prompts. Failed fetches keep local status visible, but remote counts may be outdated.
- Only explicitly queued repair tasks request agent changes. Repairs run one at a time in the selected checkout. RepoMan checks the branch, upstream, and captured remote before execution and verification. The presets describe the intended Git behavior; the agent handles execution and required interaction.
- Push/pull findings require a known upstream comparison. Stale branches have no commits in 90 days, excluding `main`, `master`, and branches checked out in any worktree. Linked worktrees exclude the primary worktree and appear as informational findings.
- Refresh skips repositories sharing the active repair’s Git common directory, including linked worktrees, while continuing to inspect other repositories. Locks and checks coordinate RepoMan work; external Git tools can still change a checkout.
- The screenshots and `--demo` mode use illustrative data. Demo mode cannot run agents, answer agent questions, cancel real tasks, or persist repair runs.
- Local packaging writes a DMG and checksum under `dist/`. Pushing a `vX.Y.Z` tag publishes them through the [release workflow](.github/workflows/release.yml). Packaged builds are signed ad hoc and are not notarized; Gatekeeper may require manual approval.
- No license is declared in this repository.

## Architecture

The diagram shows discovery and refresh. The [checks and repairs guide](docs/issues.md) explains issue detection, prompt recipes, queued agent work, and verification.

![RepoMan refresh architecture: folder discovery, refresh coordination, Git scanning, and the dashboard](docs/architecture.png)
