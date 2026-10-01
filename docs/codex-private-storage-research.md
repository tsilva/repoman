# Private Codex storage investigation

Investigated on 2026-10-01 with the installed macOS Codex CLI 0.159.2. The first experiment used a disposable prototype. The implementation described below now applies private storage to RepoMan's execution adapter.

## Conclusion

A subprocess-specific `CODEX_HOME` works for persistent RepoMan conversations. A real model turn completed, the backend exited, and a fresh backend resumed the same thread and recalled the earlier message. The thread's transcript, SQLite record, and writer lock were created under the private home, with no matching record, transcript, or lock in the default home. Desktop's 50 most recent chats did not include it.

This addresses the observed ownership conflict by separating the storage Desktop discovers from RepoMan's storage. It does not eliminate locking: a competing backend using the same private home still received the exact `already has an active writer` error. RepoMan must continue serializing replies within each conversation and releasing its backend before another process resumes that conversation.

## Experiment

The fixture set `CODEX_HOME` only in the environment passed to its child processes. It used a disposable workspace and private home under `.build/codex-home-investigation/`, selected read-only execution, and issued two short GPT-6.1 Sol turns with low reasoning effort. Neither turn used tools or changed workspace files.

| Check | Observed result |
| --- | --- |
| Empty private home | No inherited account or Desktop history |
| Authentication | Existing access token supplied over child stdin using experimental external-token login |
| First inference | Completed in about 4.4 seconds |
| Backend restart | Original backend exited; fresh backend resumed the identical thread ID |
| Conversation memory | Second turn returned the exact marker from the first, in about 5.8 seconds |
| Thread storage | One matching SQLite record in the private home; zero in the default home |
| Transcript and lock | Present only under the private home |
| Shared credentials/configuration | Default `auth.json` and `config.toml` hashes unchanged |
| Parent environment | `CODEX_HOME` unchanged |
| Private credentials | No `auth.json` written; login disappeared on backend restart |
| Token renewal | No refresh requested or attempted |
| Same-home contention | Competing backend rejected with the active-writer error |
| Desktop sidebar | Test thread absent from 50 recent chats; no unavailable hosts reported |

Desktop's `read_thread` lookup was inconclusive: it reported an unavailable durable host. The visibility evidence is the local SQLite/transcript/lock checks and sidebar listing, rather than that lookup. A visual UI check was not performed.

Evidence: [probe source](../.build/codex-home-investigation/probe.py), [sanitized results](../.build/codex-home-investigation/run-d328a9067865425aaf9f348617b1121f/report.json). All fixture backends were stopped. The disposable home and harmless conversation remain under ignored build output for inspection. No credentials were copied, symlinked, logged, or written into the fixture; only the existing access token and account identifier were passed in memory. The shared refresh token was not supplied to the backend.

## Authentication decision before implementation

Private storage does not automatically inherit Desktop's sign-in, configuration, plugins, or home-scoped skills. The external-token experiment proves authenticated inference and restart recovery, but not independent token renewal. The installed schema marks this login mode unstable and internal-use-only, while current official documentation describes it as experimental for hosts that own the authentication lifecycle. It should not be the default production integration for borrowing Desktop credentials.

Prefer a separate managed ChatGPT sign-in stored in RepoMan's private home, with an explicit credential-storage policy. Verify independent login, renewal, and logout without changing Desktop or ordinary CLI credentials. Do not copy or symlink the default credential file: sharing a managed refresh token would reintroduce authentication coupling. Independent sign-ins using the same ChatGPT account still share account usage limits.

An implementation would use a stable application support directory, apply the private home consistently to run and recovery processes, and keep application policy separate from user-global configuration. Existing repair tasks refer to threads in the default store; their transition needs an explicit design. The actual repair permission profile, command execution, wrapper selection, and user-facing sign-in flow remain untested in this prototype.

Official references: [Codex configuration and state locations](https://learn.chatgpt.com/docs/config-file/config-advanced), [app-server authentication and thread lifecycle](https://learn.chatgpt.com/docs/app-server).

## Implementation follow-up

RepoMan now passes a stable private `CODEX_HOME` to both repair and recovery backends and pins file-based credential storage. It checks account state before inference and provides the private sign-in command when needed. Legacy task transcripts are copied atomically after checking their thread ID and repository; copied paginated histories are loaded without inference to rebuild their private turn index before recovery; authentication and configuration are never imported. Source transcripts remain unchanged, and private progress takes precedence over legacy copies. Unit tests cover migration and failure cases, and a production-adapter smoke check uses the real CLI to recover an exact completed turn from a migrated prototype transcript without inference or authentication. Independent managed login and token renewal still require user testing. See [repair persistence and recovery](issues.md#persistence-and-recovery).
