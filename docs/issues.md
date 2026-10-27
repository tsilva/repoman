# Checks and issue details

RepoMan inspects local Git repositories and presents current findings. The app has no repair agent, prompt catalog, chat composer, task queue, transcript recovery or automatic issue-fixing execution. Repository maintenance happens in external tools and Codex skills. Selected-repository Refresh live in the top-right window toolbar beside the repository-opening and diff controls; the Issues panel header contains its title. Action icons use gray at rest, white on hover when enabled and darker gray when disabled; disabled icons do not highlight on hover.

## Modules

- `RepositoryIssueCatalog` registers detectors with stable IDs, categories, symbols, availability rules and validity periods.
- `RepositoryInspectionContext` bounds file and Git reads to one repository. Shared caches avoid duplicate reads within an inspection.
- `RepositoryInspectionRunner` evaluates up to four checks concurrently and publishes each completed result immediately.
- `RepositoryInspectionReport` records findings, partial results and unavailable reasons. Incomplete checks remain unknown and cannot establish that a finding is absent.
- `RepositoryInspectionCache` persists results and their original completion times. Startup and the minute scheduler run missing or expired checks; explicit refresh bypasses reuse. See [scanning performance](scanning-performance.md).
- `RepositoryStore` owns snapshots, check progress, preferences, current reports. It never loads or resumes legacy `repair-tasks.json` files.
- `RepositoryIssuesView` sorts the flat findings by check category and catalog check order, then renders the selected instance's evidence. Repository badges distinguish actionable issues, coverage limits, and information.
- `RepositoryChecker` exposes fresh catalog inspection to the CLI; `RepositoryCheckReport` serializes its results. The app calls the same catalog directly.
- `RepositoryDiff` parses unified Git diffs for read-only working-tree review.

## Selection and freshness

Results are separated into Actionable issues, Coverage limits, and Information. Each section uses a flat list, including repeated subjects and files. Informational observations do not increase actionable issue counts. There are no collapsible issue groups or group-summary views. Category order is: Git, Documentation, Repository setup, Inspection, CI. Checks retain their catalog order within a category, and instances of the same check keep their original relative order. Selecting a finding opens its complete title, subject, evidence, category and check ID. External details links and Copy maintenance task remain available. There are no selection checkboxes, repair statuses, conversation history or archive controls.

The issue list is derived only from the latest checker report. A finding disappears after a fresh check confirms it is absent. Stored conversations never synthesize findings or alter issue counts. An unavailable detector gets an incomplete row rather than appearing passed. Running and queued checks remain visible while inspection is in progress; passed checks are hidden. Selection uses stable finding identities and clears when its finding or repository is no longer visible.

Inspection stays off the main actor and preserves local status after a failed fetch. Refresh may fetch and prune remote-tracking refs but never merges, pushes, stages or changes working files. Repository checks do not establish that another writer is idle.

## Adding a check

Add a `RepositoryCheck` with a unique ID, title, category and symbol. Return findings with stable subjects and useful evidence, or a partial/unavailable result when the answer is unknown. New protocols and detectors belong in their modular check files. No UI-specific case or repair recipe is needed. Reuse the existing availability, path-containment, redaction, file-size and concurrency rules.

Detectors and default thresholds live in RepoManCore. Skills consume their results rather than copy the implementation. Editorial README reviews and live-site audits run outside RepoMan. See [additional checks](additional-checks.md). Remote detectors must declare `requiresRemoteAccess` so the CLI can omit them in local mode.

## Verification

Run `swift test` for detector, cache, flat ordering, diff parser and shared checker coverage, then build the Xcode `RepoMan` scheme. Use `--demo` for native review and `Tools/verify-window-resizing.sh` for resize and maximize/restore checks. Optional `--screenshot /absolute/path.png` captures the native test window. Demo data does not inspect real repositories.

Older issue conversation files remain on disk for the user to retain or remove independently. The app neither reads nor rewrites them and never starts repair subprocesses on startup, refresh or selection.

## Shared CLI

Build with `swift build --product repoman`, or use the CLI embedded at `RepoMan.app/Contents/Helpers/repoman` by the Xcode build. Both compile the existing core sources without additional packages. The Swift package remains macOS-only. App releases include the CLI with the same version. Source builds report `development`.

```sh
repoman --list-checks
repoman check --repo /absolute/repo --check dependencies.safeguards --check dependencies.lockfile --format json
repoman check --repo /absolute/repo --fetch --format json
repoman check --repo /absolute/repo --check ci.failing --remote --format text
python3 Tools/test_cli.py .build/debug/repoman
```

`--repo` must identify one Git working-tree root. Repeat `--check` to select checks, or omit it for the catalog. Local mode omits remote checks and includes `skipped` entries with reasons; explicitly requesting a remote check without `--remote` is an error. `--remote` enables read-only GitHub reads through the existing `gh` login, without fetching Git refs. `--fetch` separately opts into the same bounded fetch used by the app: all configured remotes (at most 16), remote-tracking branch refs only, with pruning, no tags or submodule recursion and a 45-second total deadline. It does not merge, pull, push, change branches, index or working files, or run Git hooks. Git push/pull, divergence, unpublished-branch and upstream checks remain incomplete unless this run successfully refreshes every remote and that observation is less than five minutes old. A failed refresh retains local results, explicitly reports the failure without provider output, and keeps comparisons provisional. External pulls and FETCH_HEAD timestamps are not trusted as proof that every remote was refreshed. Without a successful `--fetch`, local-ref findings are labelled provisional and informational, even with `--remote`, which does not fetch. Aligned local refs cannot establish remote health. Dashboard ahead/behind counts show `?` when provisional. No project scripts, installs, hooks, model requests or browser visits run. Git optional index writes and fsmonitor are disabled.

JSON schema version 2 contains `schemaVersion`, `checkerVersion`, `repository`, nullable `head`, ISO-8601 `observedAt`, a `remoteRefs` freshness explanation and `checks`. Each check contains `id`, `status` (`passed`, `information`, `findings`, `not_applicable`, `incomplete`, or `skipped`), an optional `reason`, `findings`, and `exceptions`. Checks containing only informational observations use `information` and retain their evidence in `findings`; checks with actionable findings use `findings`. Incomplete checks retain `incomplete` even when informational or actionable evidence is available. Findings contain their stable `id`, `subject`, `title`, redacted `evidence`, `severity`, and optional `detailsURL`. Applied exceptions map exact subjects to their repository-owned reasons; unused exceptions are omitted. A pass with exceptions means compliance under that policy, not an unconditional pass. Partial checks retain findings and stay incomplete. Checks return `not_applicable`, with a reason, when optional inputs or their repository policy do not apply. Explicitly disabled notebook checking returns `skipped`; neither state certifies a clean inspection. Missing required or unreadable inputs retain findings/incomplete coverage. Dependency checks return `not_applicable` when no supported manifests are found; this does not certify other ecosystems. The dashboard distinguishes these completed checks from passes and shows a compact count.

The uv lockfile-drift check compares dependency groups with the selected workspace package's `metadata.requires-dev`, alongside base and optional requirements. It expands nested includes within fixed bounds and compares environment-marker declarations without using the current host to discard platform-specific requirements. Invalid or unsupported declarations remain incomplete; no resolver is executed.

Tracked-secret, file-size, merge-marker and documentation-link checks continue across individual unreadable paths. Documentation checking also retains known broken targets when another link in the same document cannot be inspected. They retain findings from readable files and report incomplete coverage, with at most five path diagnostics and a count of additional failures. Exceptions can suppress findings but cannot make incomplete coverage pass. Explicit relative links into a visible, direct sibling Git working-tree root (including a `.git` file) are checked for target existence only. No sibling file contents are opened. Missing targets in available sibling repositories are findings; unavailable sibling checkouts, non-repository destinations, escapes beyond the common parent, and symlinks outside the target repository remain incomplete. General content readers remain confined to the inspected repository.

Exit 0 means the applicable selected checks completed without actionable findings; information and explicitly not-applicable checks do not cause failure. Exit 1 means actionable findings exist, including when coverage is also incomplete. Exit 2 means invocation or startup failed, with diagnostics on stderr and no report. Exit 3 means verification is incomplete without actionable findings; it must not be treated as a pass. Consumers must inspect both findings and coverage reasons. Skipped remote checks are outside local coverage and never establish remote compliance. Display toggles and ignored checks in desktop UserDefaults do not affect the CLI. File-read and containment errors identify the repository-relative path without displaying file contents or resolved symlink targets. Reports are observations of a mutable checkout, not atomic snapshots or proof of ownership. Rerun relevant checks after maintenance; do not reuse a report as publication approval.

Copy maintenance task includes the finding, original check completion time (or explicitly unknown time), and a shell-quoted verification command using the bundled executable. It only copies text. Skill invocation and any repair remain user-directed.

The existing `dependabot-cleanup` skill optionally consumes dependency reports when a local checkout and CLI are already available. Its existing package-age, compatibility, exact-revision CI, merge and publication requirements remain authoritative. There is no shared daemon, imported run history or general skill executor.

Service access metadata and local privacy checks are local-only and never inject credentials. The `github.dependabotAlerts` check uses the existing GitHub CLI login under the remote-access gate; known alerts survive incomplete pagination. Its results describe the published dependency graph rather than the mutable checkout. See [additional checks](additional-checks.md) for schema recognition and inventory bounds.
