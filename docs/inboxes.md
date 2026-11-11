# Repository inboxes

The **Inboxes** mode reads root `INBOX.md` files from RepoMan's existing repository
inventory. **All repositories** shows a grouped list; the sidebar narrows it to a
single repository without leaving Inboxes. This scope is independent of the
selected repository in Repositories mode. Traffic remains a separate GA4 view,
and the shared sidebar retains Git activity, issue counts and configured user
counts.

Select a task to read its title and supporting notes in the adjacent pane. Search
matches repository names, titles and notes. **Open** hides completed tasks;
**All** includes them. A task completed in the current selection stays visible
long enough to inspect or undo the change. **Open source** uses the default
application for Markdown files.

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

## Checkbox changes and Undo

Only an explicit checkbox click or **Undo** writes to a source file. Checkbox
editing requires the inbox to be untracked and effectively ignored, with an
explicit `/INBOX.md` rule in the repository's root `.gitignore`. Other readable
inboxes are shown as read-only. RepoMan never changes ignore rules or Git
tracking on behalf of this view.

The writer checks the displayed revision and file identity, obtains a
nonblocking advisory file lock, and updates only the checkbox's single marker
byte. It preserves surrounding content, line endings, permissions and file
identity. The saved contents are checked again before reporting success. Undo
restores the original marker, including uppercase `X`, only while the exact
saved revision remains current. A detected conflict asks the user to refresh;
it never resolves differences by rewriting the whole document.

Advisory locking coordinates cooperating writers; unrelated editors do not
necessarily use it. An uncoordinated simultaneous edit can still race with a
one-byte write. The before/after checks detect observed conflicts, and a conflict
requires reviewing the current source. This is not an exclusive editing lock
against every application.

Inbox completion records a user's checkbox decision. It does not verify that a
maintenance issue is fixed, run an agent, commit, synchronize or publish changes.
Repository inspection and the shared CLI retain their existing read-only
working-tree behavior.

## Development verification

Run `swift test` for parser, byte-preserving saves, source conflicts, Undo,
duplicate tasks and file-policy cases. Build the RepoMan scheme for native UI
changes. Run `bash Tools/verify-inboxes.sh` to exercise the store against
disposable repositories and native navigation, completion and Undo using
illustrative data. Set `REPOMAN_SCREENSHOT_DIRECTORY` to an existing ignored
directory for wide and minimum-window captures. This verification does not
query live GA accounts or edit monitored inboxes.

Use `--demo --inboxes` to open the development app on the illustrative inbox
screen. Demo checkbox changes remain in memory and never access source inboxes.
