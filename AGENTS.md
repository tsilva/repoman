# RepoMan contributor instructions

## Project skills

- Use `.codex/skills/build-release/SKILL.md` for `/build-release` and for RepoMan release builds, packaging, or GitHub publication. A bare invocation builds, verifies, and publishes a GitHub Release; explicitly local builds do not publish. Pushing a version tag is the publication trigger.

## Project layout

- `RepoMan/` contains the macOS SwiftUI app and its `RepositoryStore` refresh logic.
- `RepoManCore/` contains the Git scanner, subprocess runner, and shared models. The app and the Swift package use these sources.
- `Tests/RepoManCoreTests/` contains integration tests that create temporary Git repositories.
- `Tools/RenderDemo.swift` renders illustrative app data; `docs/repoman-demo.png` is the README screenshot.
- `image-assets/sources/` holds the editable logo and icon artwork; `RepoMan/Assets.xcassets/AppIcon.appiconset/` is the macOS app icon built into the target.

## Build and verification

- Open `RepoMan.xcodeproj` in Xcode 27 and run the `RepoMan` scheme on macOS 27 or later.
- Run `swift test` after changing `RepoManCore/` or its tests.
- For app changes, build the `RepoMan` scheme in Xcode. Use `--demo` when reviewing the UI with illustrative data.
- Keep generated output in `.build/` or `DerivedData/`; do not commit it.
- `Tools/package-dmg.sh` packages a built `RepoMan.app` into a DMG. The build-release skill helper drives tests, the Release build, signing, and validation locally and in `.github/workflows/release.yml`; `dist/` is generated output.

## Behavior to preserve

- Discover only visible direct child repositories containing a `.git` file or directory. Exclude linked worktrees from the repository list; keep their details on the primary repository.
- Keep repository inspection responsive: Git work runs off the main actor, and batches use at most four concurrent tasks.
- Refresh may fetch remote-tracking refs, but must not merge, pull, push, or change working files in monitored repositories.
- Preserve useful local status when a remote fetch fails, and keep Git prompts and operations bounded by timeouts.

## Shared release procedure

The project `build-release` skill composes `$release-workflow` from
`/Users/tsilva/.codex/skills/release-workflow/SKILL.md`.
Read both for release work; keep project commands, version policy, artifact
requirements, and approval gates in the project adapter.
