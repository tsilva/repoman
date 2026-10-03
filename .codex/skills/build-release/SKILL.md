---
name: build-release
description: Prepare, monitor, and verify RepoMan macOS releases built and published in GitHub Actions. Use for /build-release, release packaging, publication, and validation; ordinary Debug runs do not need it.
---

# Build Release

Read and apply the shared `$release-workflow` skill at
`/Users/tsilva/.codex/skills/release-workflow/SKILL.md`. It owns common preflight,
publication safeguards, `$push` integration, monitoring, and verification. This
adapter owns RepoMan's commands, version policy, and artifact requirements.

A bare `$build-release` or `/build-release` requests publication. All release
tests, compilation, signing, packaging, and artifact validation run in GitHub
Actions. Do not build a local candidate before tagging. The operator machine
needs only Python 3 for metadata reading, Git, and authenticated `gh`.
Explicitly local builds remain available below; validation and dry runs use
Actions and never create a tag or GitHub Release. Editing instructions does not
authorize publication.

## Prepare and publish

Require a clean current `main` synchronized with `origin/main`; preserve
unrelated changes and stop publication preparation when the checkout is dirty.
Resolve the actual GitHub destination and inspect its tags and published
releases before selecting a version.

Read the two committed `MARKETING_VERSION` values without running Xcode:

```bash
python3 .codex/skills/build-release/scripts/release-version.py
```

Both build configurations must have the same `X.Y.Z` version. Honor an explicit
version. Otherwise use the project's unused version if it is newer than the
latest stable published version; if already released, choose the next patch
version after that published version. With no releases, use the project's
unused version. Require the corresponding `vX.Y.Z` tag and GitHub Release to be
absent locally and remotely; failed network checks do not establish absence.

If the selected version differs, update only `MARKETING_VERSION` in both
configurations of `RepoMan.xcodeproj/project.pbxproj`. Commit and push only those
intended metadata changes using `$push`. Read the version again and require a
clean synchronized checkout at the exact full release SHA. No Xcode, Swift,
signing, or packaging commands run locally during this preparation.

Create the annotated tag at that SHA and apply `$push` to push only the exact
tag to the verified destination:

```bash
git tag -a vX.Y.Z <full-release-sha> -m "Release vX.Y.Z"
git push origin refs/tags/vX.Y.Z:refs/tags/vX.Y.Z
```

Replace `origin` when the verified release destination differs. Never move or
replace an existing tag or release. The tag triggers
[release.yml](../../../.github/workflows/release.yml). Its read-only build job
checks the tag against committed version metadata, runs `swift test`, builds an
arm64 Release app on the GitHub-hosted `xcode-27` image, applies an ad-hoc
signature, validates the bundle version, architecture and icon, and packages
and mounts the DMG to check its contents. It uploads the validated DMG and
checksum as `repoman-<full-release-sha>`.

Only the separate publication job has `contents: write`. It downloads those
exact artifacts, verifies their filenames and checksum, and publishes
`RepoMan-vX.Y.Z-macOS-arm64-adhoc.dmg` and its `.sha256` file. Never rebuild or
substitute artifacts between validation and publication.

Follow shared monitoring for the tag-push run at the exact release SHA. Require
its build and publish jobs to succeed, including fresh public downloads,
checksum comparison with the candidate, and verification that the release tag
resolves to that SHA. Report the GitHub Release and run URLs, version/tag, SHA,
asset names, and ad-hoc signing / non-notarization status. On failure, preserve
state and report the failed gate; do not automatically repeat publication.

## Validate in Actions without publication

For a dry run, release candidate validation, or a build-only request using the
committed source, dispatch the latest upstream `main` commit:

```bash
bash .codex/skills/build-release/scripts/validate-release.sh
```

This launcher performs only Git/GitHub operations locally. It may run while the
checkout contains unrelated work, because validation uses the full committed
`origin/main` SHA and excludes uncommitted changes. To validate a particular
current `main` SHA, use `gh workflow run release.yml --ref main -f ref=<full-sha>`
against the verified repository. The runner rejects stale or non-main SHAs.

Monitor the matching `workflow_dispatch` run and require the build job and
artifact upload to succeed. The publish job must be skipped. Download its
`repoman-<full-sha>` artifact and verify the DMG against the checksum before
reporting the successful run, artifact names, and that nothing was published.

## Explicit local builds and installation

Only when the user explicitly requests a local build, run:

```bash
bash .codex/skills/build-release/scripts/build-release.sh
```

It requires macOS and Xcode 27 and performs the same build and artifact checks
without tagging or publishing. Use `--version X.Y.Z` and `--output-dir DIR` only
when requested; an explicit output directory must be empty. Default output is
a fresh ignored `dist/build-release.*` directory.

For a local install request, use the helper's DMG. For a published-release
install request, download that release's DMG and checksum and verify those
bytes. Stop the running RepoMan process, replace `/Applications/RepoMan.app`
from the mounted DMG, launch the installed copy, and confirm its executable is
under `/Applications`. Preserve the previous installed app until the new copy
launches successfully. Builds are arm64, ad-hoc signed, and not notarized.
