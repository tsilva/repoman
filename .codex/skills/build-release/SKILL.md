---
name: build-release
description: Build, verify, and publish RepoMan macOS DMGs through version-tagged GitHub Releases. Use for /build-release or RepoMan release builds; explicit local builds do not publish and ordinary Debug runs do not need it.
---

# Build Release

Read and apply the shared `$release-workflow` skill at
`/Users/tsilva/.codex/skills/release-workflow/SKILL.md` before execution.
It owns common preflight, publication safeguards, `$push` integration,
workflow monitoring, verification, and reporting. The rules below are this
project's adapter; they retain its invocation default and required gates.
If the shared skill is unavailable, stop and report the missing dependency.

A bare `$build-release` or `/build-release` invocation requests the full
publication flow: build and verify the DMG, push its version tag, and monitor
the GitHub Release until its DMG and checksum are available and verified.
Explicitly local, dry-run, or inspection requests must not create or push a
tag or publish a release. Editing these instructions does not run a release.

Use the repository-owned helper for local builds and for the tag-triggered GitHub workflow. A local build does not create a tag or publish a release.

## Local build

For an explicitly local build, or to validate a publication candidate, run
from the repository root:

```bash
bash .codex/skills/build-release/scripts/build-release.sh
```

The helper reads `MARKETING_VERSION` from the Release scheme unless `--version X.Y.Z` is supplied. It requires Xcode 27, runs `swift test`, builds an arm64 Release app, applies an ad-hoc signature, checks the bundle version and icon, packages a DMG with `Tools/package-dmg.sh`, mounts and validates the DMG, and writes a SHA-256 file. Its default output directory is a new ignored `dist/build-release.*` directory. Use `--output-dir DIR` when a stable output location is needed.

For a local install request, use the DMG printed by the helper. For a published-release install request, download the requested GitHub Release's DMG and checksum and verify those downloaded bytes; do not substitute a local build. Stop the running RepoMan process, replace `/Applications/RepoMan.app` from the mounted DMG, launch the installed copy, and verify that the running executable comes from `/Applications`. Preserve the previous installed app until the replacement has launched successfully.

## GitHub publication

Publication is authorized by a bare skill invocation, a GitHub Release request,
or an explicit tag-push request. Follow the shared preflight and require a clean
current `main` synchronized with `origin/main`.

Honor an explicitly requested version. Otherwise, use the Release scheme's
`MARKETING_VERSION` if it is newer than the latest published version and unused;
if it has already been released, select the next patch version after the latest
published version. With no previous releases, use the scheme's unused version.
Verify that the target `vX.Y.Z` tag and release are absent locally and remotely.
Keep `MARKETING_VERSION` consistent in both build configurations; if it needs
changing, commit and push only the intended version changes using `$push` before
validating the clean publication candidate. Stop on version or release-state
conflicts rather than replacing tags or assets.

Run the local helper with `--version X.Y.Z` for the selected version. After its
gates pass, create an annotated `vX.Y.Z` tag at the full validated commit SHA and
apply `$push` to push only that tag to the verified `origin` destination.
The [release workflow](../../../.github/workflows/release.yml) rebuilds the tagged
source with this same helper and publishes
`RepoMan-vX.Y.Z-macOS-arm64-adhoc.dmg` and its `.sha256` file. Follow shared
monitoring for the exact tag-push SHA, download both published assets, and verify
the published DMG against its checksum before reporting success. Compare the
published assets with each other, not with the separately built local candidate.

These builds are ad-hoc signed and not notarized. Report that status with the artifact path or release URL.
