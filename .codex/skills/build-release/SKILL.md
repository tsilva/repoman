---
name: build-release
description: Build and verify RepoMan macOS DMGs, and coordinate version-tagged GitHub Releases when publication is requested. Use for /build-release or RepoMan release builds; ordinary Debug runs do not need it.
---

# Build Release

Use the repository-owned helper for local builds and for the tag-triggered GitHub workflow. A local build does not create a tag or publish a release.

## Local build

From the repository root, run:

```bash
bash .codex/skills/build-release/scripts/build-release.sh
```

The helper reads `MARKETING_VERSION` from the Release scheme unless `--version X.Y.Z` is supplied. It requires Xcode 27, runs `swift test`, builds an arm64 Release app, applies an ad-hoc signature, checks the bundle version and icon, packages a DMG with `Tools/package-dmg.sh`, mounts and validates the DMG, and writes a SHA-256 file. Its default output directory is a new ignored `dist/build-release.*` directory. Use `--output-dir DIR` when a stable output location is needed.

For an install request, use the DMG printed by the helper. Stop the running RepoMan process, replace `/Applications/RepoMan.app` from the mounted DMG, launch the installed copy, and verify that the running executable comes from `/Applications`. Preserve the previous installed app until the replacement has launched successfully.

## GitHub publication

Only publish when the user asks for a GitHub Release or explicitly authorizes a tag push. Require a clean current `main`, synchronize with `origin/main`, and check that the `vX.Y.Z` tag and release do not already exist. The [release workflow](../../../.github/workflows/release.yml) runs this same helper when a version tag is pushed, then uploads the DMG and checksum. Monitor the workflow and confirm the release URL and exact asset names. Do not tag, push, replace assets, or publish as a side effect of a local build request.

These builds are ad-hoc signed and not notarized. Report that status with the artifact path or release URL.
