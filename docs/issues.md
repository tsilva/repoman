# Repository checks and actions

RepoMan separates inspection, findings, and actions. The app renders registered metadata instead of adding a screen for every check.

1. `GitRepositoryScanner` gathers a `RepositorySnapshot` off the main actor. Root file names are collected with local Git status; an unavailable root listing stays unknown rather than producing false missing-file findings.
2. `RepositoryIssueCatalog` runs pure, inexpensive `RepositoryCheck.detect` functions against the snapshot. A `RepositoryFinding` contains a stable repository/check/subject ID, evidence, category, severity, symbol, and action IDs.
3. `RepositoryActionCatalog` resolves those IDs to registered preparation and execution handlers. Preparation returns a reviewable `RepositoryActionPlan`; execution applies the plan only after the user requests it.
4. `RepositoryStore` coordinates previews and results away from the main actor, then replaces the affected snapshots. `RepositoryIssuesView` presents one flat list for the selected repository. The view also accepts a global check scope for future batch interfaces.

## Add a detector

Add inspection data to `RepositorySnapshot` and gather it in the scanner if necessary. Keep subprocesses and filesystem work out of detector closures. Register a `RepositoryCheck` with a unique, stable ID in `RepositoryIssueCatalog.standardChecks`, returning zero or more findings. Point each finding at existing or new action IDs.

The repository issue list, count badges, filtering, and overflow check menu derive from this catalog. Per-repository ignored checks and globally disabled checks persist by check ID. Worktrees and stale branches appear as informational findings without automatic fixers. Zero counts do not produce findings.

## Add a fixer

Register a `RepositoryActionDefinition` in `RepositoryActionCatalog.standardActions`. Provide a title, apply-button label, input kind, batch capability, mutation flag, and Sendable preparation/execution handlers. The existing input kinds support no input, file selection plus commit message, and license selection; a new interaction type needs a corresponding generic input form.

Preparation should inspect current preconditions and call `RepositoryActionPlan.capture` to bind its preview to current repository state. Return a preview and, for an editable file draft, an output path and content. Execution must repeat action-specific preconditions, apply exactly the reviewed operation, and return a fresh snapshot plus a result message. Never execute during detection or ordinary refresh.

The catalog validates captured HEAD, branch, upstream, remote configuration, Git status, and selected file hashes before execution. It serializes its actions by Git common directory, including linked worktrees. These locks coordinate RepoMan operations; they do not stop external Git tools. Repeat checks immediately before mutation and use Git's own conflict protection and non-overwriting file writes.

Set `refreshRemoteBeforePreview` for actions that depend on current remote refs. Pull and push fetch again before execution and reject changed upstream state. Pull permits only fast-forward updates from a clean tree; push uses an explicit upstream remote/branch refspec without force. Divergence is inspection only. Selected-file commits include full working-file contents and preserve unrelated staged files; staged renames and active merge/rebase operations are blocked.

## Batch actions and verification

Only mark an action batch-capable when one input can produce independently reviewable plans for every repository. The shared view and runner support batch previews with editable drafts and a separate blocked/ready/result row per repository; the current main window presents individual repository issues. Preparation and execution run sequentially off the main actor; failures do not discard other repositories' results.

Add integration tests under `Tests/RepoManCoreTests` using temporary repositories. Cover the detector's evidence, preview without mutation, successful execution, stale-plan rejection, and preservation of unrelated work. Remote tests use a temporary local bare repository. Run `swift test` and build the macOS scheme for UI changes. `--demo` plans are explicitly non-executable.
