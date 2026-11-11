# RepoMan contributor instructions

## Project skills

- Use `$private-skills_repo-maintenance` from `/Users/tsilva/.codex/skills/private-skills/private-skills_repo-maintenance/SKILL.md` for iterative CLI-driven repository maintenance. The shared skill assesses checker quality first, repairs confirmed checker problems within authorized scope, and reruns before proposing repository fixes. Ambiguous policy changes or expanded scope require a user decision. Maintain the workflow in `private-skills`.
- Use `.codex/skills/repoman_build-release/SKILL.md` for `/repoman_build-release` and for RepoMan release builds, packaging, or GitHub publication. A bare invocation builds, verifies, and publishes entirely in GitHub Actions; explicitly local builds use the helper without publishing. Validation and dry runs also build in Actions. Pushing a version tag is the publication trigger.

## Project layout

- `RepoMan/` contains the macOS SwiftUI app and its `RepositoryStore` refresh logic.
- `RepoManCLI/` contains the shared read-only command-line entrypoint, embedded at `RepoMan.app/Contents/Helpers/repoman` by `Tools/build-cli.sh`.
- `RepoManCore/` contains the Git scanner, subprocess runner, and shared models. The app and the Swift package use these sources.
- `Tests/RepoManCoreTests/` contains integration tests that create temporary Git repositories.
- `Tools/RenderDemo.swift` renders illustrative app data; `docs/repoman-demo.png` is the README screenshot.
- `image-assets/sources/` holds the editable logo and icon artwork; `RepoMan/Assets.xcassets/AppIcon.appiconset/` is the macOS app icon built into the target.

## Build and verification

- Open `RepoMan.xcodeproj` in Xcode 27 and run the `RepoMan` scheme on macOS 27 or later.
- Run `swift test` after changing `RepoManCore/` or its tests. After CLI changes also run `python3 Tools/test_cli.py .build/debug/repoman` (use `swift build --product repoman` first if needed).
- For app changes, build the `RepoMan` scheme in Xcode. Use `--demo` when reviewing the UI with illustrative data.
- After every fix, rebuild and relaunch the development build so the running app includes the latest changes. Confirm that it launches successfully before reporting completion.
- Keep generated output in `.build/` or `DerivedData/`; do not commit it.
- `Tools/package-dmg.sh` packages a built `RepoMan.app` into a DMG. The repoman_build-release skill helper drives tests, the Release build, signing, and validation in `.github/workflows/release.yml`. Run it locally only for an explicitly requested local build; `dist/` is generated output.

## Behavior to preserve

- Discover only visible direct child repositories containing a `.git` file or directory. Exclude linked worktrees from the repository list; keep their details on the primary repository.
- Keep repository inspection responsive: Git work runs off the main actor, and batches use at most four concurrent tasks.
- Refresh may fetch remote-tracking refs, but must not merge, pull, push, or change working files in monitored repositories.
- The Inboxes view is the explicit user-action exception: a checkbox or Undo may change only the selected root `INBOX.md` checkbox marker, with revision and file-safety checks. Inbox inspection and refresh remain read-only. Keep inbox todos separate from detected issues.
- Keep Repositories, Traffic and Inboxes as peer modes. Preserve GA4 traffic reports, repository-row user counts and their independent refresh behavior when extending navigation.
- GA4 automatic renewal is an explicitly installed Mac-side service using `Tools/install-traffic-renewal.py` and the already-approved `ga4-reporting` / `ga4-realtime` broker profiles. RepoMan and its readers never retrieve tokens or renew administrator logins. Preserve an authorized standing renewal service during ordinary reporting cleanup; disabling it requires a user request. See `docs/website-checks.md` for setup, status and removal.
- Preserve useful local status when a remote fetch fails, and keep Git prompts and operations bounded by timeouts.

## Shared release procedure

The project `repoman_build-release` skill composes `$private-skills_release-workflow` from
`/Users/tsilva/.codex/skills/private-skills/private-skills_release-workflow/SKILL.md`.
Read both for release work; keep project commands, version policy, artifact
requirements, and approval gates in the project adapter.
