# Reviewed secret-scanning fixtures

The pinned Infisical scanner still runs all built-in rules. The workflow excludes
only a reviewed finding whose exact repository path, rule ID, and SHA-256 digest
of its complete matched text equal an entry in `secret-scanning-exceptions.json`.
The file contains no credential values. No whole files, rules, commits, datasets,
or notebook types are exempt. A changed value or a match in another file still
fails the check. Invalid exception files fail the check as well.

Reviewed on 2026-10-07:

- `Tests/RepoManCoreTests/RepositoryHealthChecksTests.swift` (`private-key`): Deliberately invalid private-key fixture tests secret detection and redaction.

Reviewed on 2026-10-27:

- `Tests/RepoManCoreTests/RepositoryCheckReportTests.swift` (`private-key`): Deliberately invalid private-key header fixture tests that an exception cannot hide incomplete coverage. The pinned scanner reproduced the exact finding; changing the fixture in the same file remains detected.

Do not add an exposed credential to this list. Revoke or rotate it and remove it
from source first. Inspect candidate exceptions privately and test that a changed
credential in the same file is detected before accepting an exception.

Raw scanner reports can retain source text despite `--redact`. The workflow reads
and filters them in a temporary directory, publishes only location metadata, and
deletes the report without uploading it. Run **Actions → Secret scanning → Run
workflow** with `full_history` enabled to verify reviewed history. There is no cron
or automatic retry. An unconfigured local CLI scan can still report these fixtures.

The workflow emits at most 100 error annotations using the fixed title
`RepoMan secret scan: <rule-id>`, a repository-relative file and a positive line
number. The message is constant; no match or source excerpt is published. Paths
with control characters, traversal, absolute locations or unsupported separators
are omitted, and workflow-command property values are escaped.

RepoMan requests at most 20 annotations per check run, reads only path, title and
start line, and accepts this protocol only from the `github-actions` publisher.
Other annotations are ignored; a truncated list is disclosed. CI failure detection
still works when safe annotations are absent. The prefix identifies this
metadata format; it is not an independent attestation that a finding is valid.
