# Detectors, repair recipes, and agent tasks

RepoMan detects issues, lets the user choose repair instructions, queues agent work, and verifies the result with fresh inspection. Repairs have one shared composer and task runner; there are no commit forms, license forms, file templates, or native mutation handlers.

## Modules

- `GitRepositoryScanner` gathers local Git and root-file status off the main actor. Unknown inspection stays unknown. Ordinary refresh may fetch refs but never repairs repositories.
- `RepositoryIssueCatalog` registers detectors with stable IDs. `RepositoryInspectionContext` shares read-only file inspection across content-based checks. Detectors run in batches of at most four and return findings or an explicit unavailable result.
- `RepairRecipeCatalog` contains named prompt recipes. Findings reference zero or more recipe IDs; custom instructions are available for every finding.
- `RepairTaskQueue` owns atomic persistence, duplicate prevention, concurrent scheduling, preflight, interaction state, recovery, and verification.
- `RepairAgent` is the execution seam. `CodexAgent` implements it using native stdio app-server JSON messages; tests use fake adapters and an executable protocol fixture.
- `RepositoryStore` publishes task and inspection results to SwiftUI. `RepositoryIssuesView` presents the shared prompt composer. `RepositoryRepairTrajectoryView` renders the selected issue's conversation inside its details. There is no Tasks screen or history navigation.

## Add a detector

For a check using existing snapshot information, register a `RepositoryCheck` with a unique ID, metadata, an availability closure when inspection can fail, and a pure detection closure. Return zero or more `RepositoryFinding` values. Each finding must identify the repository, detector, and stable subject. Evidence text is not part of its identity.

For a content-based or asynchronous check, use the inspection initializer:

```swift
RepositoryCheck(id: "docs.unfinished", title: "Unfinished notes",
                category: .documentation, symbol: "doc", inspect: { context in
    let text = try context.readText("notes.txt")
    guard text.contains("TODO") else { return [] }
    return [RepositoryFinding(
        repositoryID: context.snapshot.id, checkID: "docs.unfinished",
        subject: "notes.txt", title: "Unfinished notes", evidence: "TODO remains",
        category: .documentation, symbol: "doc", recipeIDs: ["docs.finish"])]
})
```

File reads are shared within an inspection, accept UTF-8 files up to 1 MiB, and reject paths or resolved symlinks escaping the repository. A failed read makes the detector unavailable; it never proves absence. New content checks do not require new snapshot fields, UI cases, or runner changes.

The cheap snapshot-only `findings(in:)` convenience is suitable for existing synchronous checks and demo data. Production refresh and repair verification use `inspect(_:)`, including extended detectors. Failed checks appear as unavailable information in the issue view. Display filtering uses registered check IDs; verification ignores display filters.

## CI detectors

`RepositoryCIChecks` registers `ci.failing` and `ci.coverage` in the CI category. Both use extended inspection and the ordinary recipe, filtering, and verification paths. `RepositoryFinding.detailsURL` optionally links to a reported failure; older persisted findings remain readable.

`GitHubCI` uses one read-only GraphQL query through the installed GitHub CLI to collect check runs and legacy status contexts for the latest published default and tracked branch commits. Summary scans include the tracked remote URL so every repository can be checked. No token is copied or read by RepoMan. The subprocess disables prompts, drains output concurrently, caps responses at 2 MiB, and has a 15-second timeout with a termination fallback. Errors, incomplete pagination, missing tracked branches, cancelled checks, pending checks, and absent results cannot verify an earlier failure as resolved. Failure identity belongs to the remote repository and survives commits and reruns.

Coverage inspection reads bounded local workflow files through the shared context. It recognizes common validation commands and standard push/PR trigger syntax; tag-only releases and dependency review are insufficient. Documentation-only repositories are skipped. Custom execution, external CI, and unsupported workflow syntax stay unavailable when coverage cannot be established. Tests use temporary workflows, injected status loaders, GraphQL fixtures, and a timeout executable, without contacting GitHub.

## Add a repair recipe

Register data and reference its ID from a finding:

```swift
RepairRecipe(id: "docs.finish", title: "Finish the notes",
             prompt: "Inspect the unfinished notes and complete them accurately. Leave changes uncommitted.")
```

Recipes are Codable values with an ID, title, and prompt. They contain no execution closures or specialized inputs. Multiple detectors can share one recipe. The user can edit a preset or supply a custom prompt; only clicking Send or pressing ⌘Return enqueues work. The conversation keeps its original prompt and captures every submitted follow-up. Selecting a preset fills the initial draft and never starts a turn. The preset selector disappears after the first submission, including when reopening an existing conversation.

RepoMan adds the checkout, branch, issue identity, fresh preflight evidence, and common preservation instructions. The agent reads repository instructions and collects missing information through the generic task interaction interface. License choice, cleanup scope, and history reconciliation remain intentional decisions rather than defaults inferred by the app.

## Task lifecycle

A repair task is one issue conversation, with a stable local ID and Codex thread ID. Each submitted message queues a new turn; follow-ups resume the same Codex thread and send the latest request with fresh issue context. Previous turns stay in the conversation. Only explicit submissions start inference.

Turns progress from Queued to Running, optionally Needs input, then Checking. Terminal states include Resolved, Still present, Couldn’t verify, Failed, Cancelled, and No longer needed. Execution and verification are separate stored outcomes: cancellation or failure can leave a repair complete, and successful execution can leave the issue unresolved.

Before starting, the queue inspects fresh state and checks the original branch, upstream, and any captured remote. An already-absent finding ends as No longer needed without invoking the agent. Unavailable inspection blocks execution. Duplicate active submissions return the existing conversation without adding a message. An idle unresolved conversation accepts a follow-up. Confirmed absence closes it; a later recurrence of the finding gets a new conversation while the closed record stays stored. Failures do not discard later queued tasks.

Different issue conversations run independently, including issues in the same repository. Each active turn has its own agent adapter and connection; cancellation and question answers route by conversation ID. The scheduler runs at most four turns concurrently, and queued turns start as slots become available. A single issue never runs overlapping turns. While any task holds a Git common-directory identity, refresh skips that repository and linked worktrees. Finishing one chat does not clear another chat's busy identity. Other repositories can still be refreshed explicitly. Automatic checks across all repositories run once at startup; there is no periodic refresh. Choosing a folder checks its repositories, and repairs verify the affected repository when work stops. The selected checkout is used directly; RepoMan does not create branches or worktrees for repairs. External applications remain able to change repositories, so the agent must preserve unrelated work and verification must recheck the target.

Codex is discovered automatically and uses its existing authentication. Every new repair pins `gpt-6.1-sol` with `high` reasoning effort on thread creation, thread resume, and every turn start; model fallback is disabled and the resolved thread settings are checked before inference.

Repairs use a fresh named permission profile supplied through process arguments, with approval policy `never`. The selected repository is writable, including its local `.git`, `.codex`, and `.agents` directories; sandboxed commands cannot read or write unrelated repositories or personal files. Symlinks in those special directories do not grant access to targets outside the repository. Minimal platform paths, installed Codex executables, and system CLI alias directories remain readable so commands and Codex filesystem helpers can run. Each turn uses a private temporary directory inside the repository (under `.git` when it is a local directory); temporary and common package-cache environment variables point there, and the directory is removed after execution. Git commands use repository-local configuration without reading global or system Git configuration. No persistent permission configuration is added to monitored repositories or user settings. Public network access remains enabled, subject to existing network controls. The resolved profile, approval policy, working directory, sandbox mode, extra writable roots, and exclusion of shared temp directories are checked before inference; unsupported clients or mismatches block the repair. Repository or executable paths containing quotes, backslashes, or control characters are rejected because the installed CLI cannot safely generate sandbox rules for those paths. The same profile is selected again on turn start. Command, file-change, and permission-expansion approval requests are denied. Codex execution-policy `allow` rules can run commands outside this profile even with approvals disabled; a permission profile alone is not a hard boundary when those rules are loaded. The installed app-server has no documented per-session `--ignore-rules` equivalent. These permissions govern local sandboxed commands; plugins, MCP, connectors, and browser tools have separate controls, so this is not whole-process isolation.

RepoMan enables `features.default_mode_request_user_input` for new and resumed sessions and supplies Default execution-mode instructions to ask questions through `request_user_input_async` when available, otherwise `request_user_input`, including clarifications, choices, and user-requested confirmations. Both blocking question requests and asynchronous agent messages with structured questions render an answer widget in issue details with selectable options, descriptions where provided, and custom text. No option is selected automatically; Send answers requires a nonempty answer to every question. Blocking answers return to the same live tool request. Asynchronous answers are saved and sent as a follow-up in the same Codex thread after the current turn finishes, preserving one active turn per issue. Unanswered asynchronous questions survive turn completion, verification, and restart; answered question IDs prevent recovery from reopening them. Older unfinished conversations are read once to restore question metadata that previous versions displayed as prose, without resubmitting their original prompt. Submission failures leave the widget available for retry, and duplicate submissions are rejected. Unsupported agent requests fail without granting approval. Initialization and control requests are bounded to 45 seconds; the live run is bounded to one hour, including interaction waits. Cancellation requests turn interruption, with a bounded shutdown fallback.

When work stops, including cancellation or failure, the queue gathers fresh local state and remote refs, runs the registered detector, and matches the original finding identity. Only successful absence verification resolves it. Failed fetches cannot establish remote-dependent absence; unknown files or branch/worktree inspection cannot establish their corresponding absence. Other findings are refreshed too.

Ignoring or disabling a check affects display only. Removing the detector or changing the target makes verification unknown rather than successful.

## Persistence and recovery

Codex conversations live in RepoMan's private persistent home, `~/Library/Application Support/RepoMan/Codex`. Every repair, follow-up, and recovery subprocess receives this `CODEX_HOME` in its own environment; shell profiles, Desktop settings, and the ordinary CLI home are not changed. Credential storage is explicitly file-based in the private home, so its sign-in and logout do not use Desktop's keychain slot. Configuration and credentials from the shared home are not copied. New conversations are named `[repository] Fix issue title` before the first repair turn, and follow-ups preserve the title. These private sessions are outside Desktop's default conversation store. If naming is unavailable, RepoMan reports it in activity and continues the repair.

Before inference, RepoMan checks the private account without forcing a refresh. If it needs authentication, the issue reports a Terminal sign-in command using the exact selected executable and private home. A typical command is:

```sh
env CODEX_HOME="$HOME/Library/Application Support/RepoMan/Codex" codex -c 'cli_auth_credentials_store="file"' login
```

Sign in and then retry the issue message. Credentials and automatic renewal stay in the private home; shared account usage limits still apply. This version does not provide an in-app sign-in flow.

On first continuation or recovery of a legacy task, RepoMan finds its exact transcript in the old home (`CODEX_HOME` inherited by RepoMan, or `~/.codex`), checks the recorded thread and repository, and atomically copies it into the private store. Archived transcripts can also be copied for continuation. The source remains unchanged, and newer private history is never overwritten. Missing or mismatched transcripts block continuation with an explicit error rather than replaying the initial prompt or silently starting an unrelated conversation. Once a private session is acknowledged, `codexStorageVersion: 1` prevents future recovery from importing old shared history.

All issues with submitted messages and their conversations live in `~/Library/Application Support/RepoMan/repair-tasks.json`, including resolved conversations. Resolution completes the existing record through its Resolved or No longer needed state. Completed conversations remain visible until the user archives them with the archive button in the top right of issue details. Explicit archiving stores an `archivedAt` timestamp without deleting history or changing the verification result; old records without that field remain unarchived. Active conversations must be stopped before archiving. A failed archive save restores the visible conversation and reports the error. Each record stores the original finding, target, initial prompt, submitted follow-ups, Codex thread and latest turn IDs, message/tool entries, execution result, and verification. Writes are atomic and directory/file permissions are restricted. A corrupt store or failed save blocks new execution and reports the error. A failed follow-up save restores the previous conversation without submitting it.

On launch, idle unresolved and closed conversations keep their local IDs, Codex thread IDs, and full message history. Running, input-waiting, or checking turns become Interrupted; legacy unresolved conversations without current question metadata are also reconciled once. The adapter reads the exact saved turn, restores completed items and unanswered asynchronous questions, and the queue checks current repository state. A newly copied paginated transcript may need its private SQLite turn index rebuilt: recovery loads that thread with read-only permissions and rereads the saved turn, without starting inference. It never automatically resubmits the original prompt, and it never mistakes a previous turn for a new message that has no acknowledged turn ID. Queued messages and explicitly submitted answers resume once scanning finishes; idle chats do not start inference automatically. Explicit follow-ups resume the stored Codex thread.

Streaming deltas are saved in batches during execution. Normal application quit synchronously flushes the latest buffered text and tool output before termination; a failed flush cancels quitting and reports the storage error. A force quit or crash can interrupt a pending batch, so recovery also reads available saved turn items from Codex.

The live stream uses turn-scoped agent item IDs to keep assistant prose and shell operations separate, including interleaved output and authoritative completed messages. Initial instructions and follow-ups are read-only user messages. Shell commands are expandable rows with distinct command/output formatting and exit status. Messages, tool output, and per-turn verification notices remain stored; conversation entries are not truncated by the former activity-buffer limit.

The issue detail opens the unresolved conversation for that finding or the conversation already displayed when resolution occurs. The composer stays below the stream, grows with its draft, and scrolls when needed. Its send/stop button stays at the bottom of the text field even for long drafts; there is no execution button in the panel header. A subtle animated thinking/working indicator appears in the assistant stream until the turn stops, with separate progress for queued turns, recovery, and detector verification. Selecting another issue or repository keeps every conversation running; returning to an unresolved issue restores its latest thread. Unresolved chats remain selectable even when a detector is unavailable or another turn’s inspection temporarily stops detecting their findings. Once a fresh detector confirms absence, the conversation closes and accepts no further messages. Ordinary inspections can also close idle conversations on confirmed absence. Closed issues stay in the issue list with a Completed state, while their conversations remain selectable and readable in details. Selection follows the task ID as the row changes from a current finding to a closed occurrence.

`RepositoryIssueListItem` combines current findings with conversations from the shared store. Its default query includes outstanding issues; `includeCompleted: true` also includes completed, unarchived conversations with separate identities for each occurrence. `includeArchived: true` is available for querying stored history, but the UI excludes explicitly archived conversations. Repository, check, and ignored-check filters apply to all displayed items. Both repository rows and the Issues panel show nonzero badges for Not started, Processing, Waiting for you, Completed, and Error using the same status mapping as issue rows. Completed counts include each visible occurrence; archived records contribute no counts. Outstanding finding queries and the Needs attention filter exclude completed conversations. Archiving an unresolved conversation hides its history, but its detector finding remains available to start a new conversation. Selection advances to a visible issue after archiving.

## Verification

Run `swift test` and build the macOS RepoMan scheme. Tests use temporary Git repositories and cover repair verification, new findings, stale targets, duplicate submissions, persistence failure, concurrent scheduling, linked-worktree identity, isolated cancellation and questions, parallel issues in the same checkout, bounded concurrency, custom content detectors, restart recovery without replay, follow-ups in the same thread, idle and closed persistence, full conversation retention, and closure after external repairs.

Executable protocol fixtures exercise the Codex handshake, events arriving before responses, questions, approvals, cancellation, diff streaming, thread resume, and recovery of saved items from thread reads without model inference. Set `REPOMAN_VERIFY_CODEX=1` when running tests to additionally check the installed Codex app-server with an invented thread read and a thread start cancelled before inference. The opt-in checks also exercise the actual macOS sandbox with temporary fixtures, verifying repository and Git writes, denied outside reads and writes, and symlink confinement. They make no inference requests or changes to monitored repositories; the start check can leave an empty local Codex session.

For visual review, compile `Tools/RenderDemo.swift` with app sources (excluding `RepoManApp.swift`) and core sources. Use `--demo` for the composer, or `--demo --trajectory` for a live conversation in issue details. Generated renders belong under `.build/` or `DerivedData/`. Demo mode never executes agents or persists conversations.

## Additional checks

The standard catalog also registers dependency, workflow, repository hygiene and published metadata detectors. Their presets use the same explicit-send agent workflow and fresh verification. See [additional checks](additional-checks.md) for IDs, evidence, repository exceptions, notebook opt-in, supported configuration syntax and inspection limits.
