# RepoMan contributor instructions

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
- `Tools/package-dmg.sh` packages a built `RepoMan.app` into a DMG. The tag-triggered `.github/workflows/release.yml` builds and publishes release assets; `dist/` is generated output.

## Behavior to preserve

- Discover only direct child directories containing a `.git` file or directory, including linked worktrees.
- Keep repository inspection responsive: Git work runs off the main actor, and batches use at most four concurrent tasks.
- Refresh may fetch remote-tracking refs, but must not merge, pull, push, or change working files in monitored repositories.
- Preserve useful local status when a remote fetch fails, and keep Git prompts and operations bounded by timeouts.
