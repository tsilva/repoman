# Repository inboxes

The **Inboxes** mode reads root `INBOX.md` files from RepoMan's existing repository
inventory. **All repositories** shows a grouped list; the sidebar narrows it to a
single repository without leaving Inboxes. This scope is independent of the
selected repository in Repositories mode. Traffic remains a separate GA4 view.
The Repositories sidebar retains Git activity and issue counts.

In Inboxes, sidebar rows show only the repository name and its number of open
inbox todos. Completed tasks are excluded from this count even when **All** tasks
are shown. The sidebar defaults to most open todos first, with repository names
breaking ties. Its **With open todos** filter is enabled by default to hide
repositories without open inbox tasks; search applies alongside that filter.
The sort menu also offers
name order and ascending or descending order. These preferences are saved
separately from the Repositories sidebar. Counts update after completion, Undo
and inbox refresh. A dash indicates an inbox has not been read or is unavailable;
its tooltip distinguishes that state from a readable inbox with zero open todos.

Tasks use the full content width, with no separate details pane. Long source
items show a compact first-sentence summary; expand a row to read its complete
original text and supporting notes in place. Expansion state survives tab changes.
Summaries affect presentation only: a checkbox still completes the entire source
item, and the app does not rewrite its wording or experiment history. Search
matches the complete repository names, task text and notes, including collapsed
content. **Open** hides completed tasks; **All** includes them. Recently completed
tasks stay visible long enough to inspect or undo the change. Each repository's
**INBOX.md** link opens the source in the default Markdown application.

Drag the grip at the right of a todo to reorder it within its repository. A blue
insertion line shows whether it will land above or below the target row. The
complete task and its notes move together, and the order is saved to `INBOX.md`.
Reordering also works with search and the **Open** filter: other tasks keep their
relative order. Tasks cannot move between repositories or across headings.
VoiceOver exposes **Move up** and **Move down** actions on the grip. Read-only
inboxes do not offer a grip. **Undo** reverses the latest completion or reorder.

## Source format and coverage

Tasks are Markdown checkboxes under a level-two `## Todos` heading. Unordered
and ordered list markers, Unicode text, LF/CRLF endings and uppercase `X` are
supported. Notes following a task stay with that task until the next task or
heading. Notes sections, fenced examples and HTML comments are not interpreted
as actions. The renderer treats inbox contents as data and does not execute
repository code.

Discovery follows the same direct-child, primary-checkout inventory as the rest
of RepoMan. A missing inbox is reported separately from an unreadable or
unsupported one. Missing files are never created. Inboxes without tasks and
searches without matches have separate empty states. Files must be regular UTF-8
text of at most 1 MiB. Linked files or folders, hard-linked files, and paths
within detected Obsidian vaults are unavailable.

While the mode is visible, RepoMan refreshes inbox contents every five seconds.
It does not run repository issue scans or fetch Git remotes for this refresh.
Explicit refresh is available in the toolbar and through the normal Refresh
keyboard command. Editing-policy status is cached for up to a minute; every
write independently verifies the current policy.

## Editing and Undo

Only an explicit checkbox click, reorder drop or **Undo** writes to a source file. Inbox
editing requires the inbox to be untracked and effectively ignored, with an
explicit `/INBOX.md` rule in the repository's root `.gitignore`. Other readable
inboxes are shown as read-only. RepoMan never changes ignore rules or Git
tracking on behalf of this view.

The writer checks the displayed revision and file identity, obtains a
nonblocking advisory file lock, and updates only the checkbox's single marker
byte. It preserves surrounding content, line endings, permissions and file
identity. Reordering writes the changed span of complete task blocks at the same
file size; headings, other sections and each position's trailing line endings
remain unchanged. Markdown that would change interpretation when moved is
rejected. The saved contents are checked again before reporting success. Undo
restores the exact prior order or original checkbox marker, including uppercase
`X`, only while the exact saved revision remains current. A detected conflict
asks the user to refresh; the writer never merges external changes.

Advisory locking coordinates cooperating writers; unrelated editors do not
necessarily use it. An uncoordinated simultaneous edit can still race with a
write. Reordering touches a larger span than a checkbox edit. The before/after
checks detect observed conflicts, and a conflict
requires reviewing the current source. This is not an exclusive editing lock
against every application.

Inbox completion records a user's checkbox decision. It does not verify that a
maintenance issue is fixed, run an agent, commit, synchronize or publish changes.
Repository inspection and the shared CLI retain their existing read-only
working-tree behavior.

## Development verification

Run `swift test` for parser, byte-preserving saves, reordering, source conflicts, Undo,
duplicate tasks and file-policy cases. Build the RepoMan scheme for native UI
changes. Run `bash Tools/verify-inboxes.sh` to exercise the store against
disposable repositories and native drag reordering, navigation, completion and
Undo using illustrative data. Native drag checks require macOS event-posting
access and activate the disposable demo window. Set `REPOMAN_SCREENSHOT_DIRECTORY` to an existing ignored
directory for wide and minimum-window captures. This verification does not
query live GA accounts or edit monitored inboxes.

Use `--demo --inboxes` to open the development app on the illustrative inbox
screen. Demo completion and reorder changes remain in memory and never access source inboxes.
