---
name: repoman_build-release
description: Build, publish, verify, and install RepoMan macOS releases, replacing the installed app and cleaning up obsolete copies. Use for /repoman_build-release, release packaging, publication, validation, and local installation; ordinary Debug runs do not need it.
---

# Build Release

Read and apply the shared `$private-skills_release-workflow` skill at
`/Users/tsilva/.codex/skills/private-skills/private-skills_release-workflow/SKILL.md`. It owns common preflight,
publication safeguards, `$private-skills_push` integration, monitoring, and verification. This
adapter owns RepoMan's commands, version policy, and artifact requirements.

A bare `$repoman_build-release` or `/repoman_build-release` requests publication. All release
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
python3 .codex/skills/repoman_build-release/scripts/release-version.py
```

Both build configurations must have the same `X.Y.Z` version. Honor an explicit
version. Otherwise use the project's unused version if it is newer than the
latest stable published version; if already released, choose the next patch
version after that published version. With no releases, use the project's
unused version. Require the corresponding `vX.Y.Z` tag and GitHub Release to be
absent locally and remotely; failed network checks do not establish absence.

If the selected version differs, update only `MARKETING_VERSION` in both
configurations of `RepoMan.xcodeproj/project.pbxproj`. Commit and push only those
intended metadata changes using `$private-skills_push`. Read the version again and require a
clean synchronized checkout at the exact full release SHA. No Xcode, Swift,
signing, or packaging commands run locally during this preparation.

Prepare the full release title `RepoMan vX.Y.Z` and body for the user's draft
approval before pushing the publication trigger. Put the approved title, a
blank line and the complete approved body in an external annotation file.
Create the annotated tag at that SHA and apply `$private-skills_push` to push
only the exact tag to the verified destination:

```bash
git tag -a vX.Y.Z <full-release-sha> --cleanup=verbatim -F /external/release-annotation.txt
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
For publication, the workflow also carries the approved tag body as
`release-notes.md` in this candidate artifact. Its title must match the
tag and its body must be nonempty. Validation-only runs do not need release notes.
Keep `--cleanup=verbatim`: Git's default tag cleanup can strip Markdown headings.

Only the separate publication job has `contents: write`. It downloads those
exact artifacts, verifies their filenames and checksum, and publishes
`RepoMan-vX.Y.Z-macOS-arm64-adhoc.dmg` and its `.sha256` file. Never rebuild or
substitute artifacts between validation and publication. Publication uses the
approved notes file without generating extra text, then verifies the published
title and body against the candidate.

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
bash .codex/skills/repoman_build-release/scripts/validate-release.sh
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
bash .codex/skills/repoman_build-release/scripts/build-release.sh
```

It requires macOS and Xcode 27 and performs the same build and artifact checks
without tagging or publishing. Use `--version X.Y.Z` and `--output-dir DIR` only
when requested; an explicit output directory must be empty. Default output is
a fresh ignored `dist/build-release.*` directory.

For development builds and installs, add `--development`. This keeps Release
optimization and compiles the `DEV` Dock badge into the app, including when it
runs from `/Applications/RepoMan.app`. Use this flag for routine local development
installs; omit it for production-parity artifacts and published releases. Debug
builds also show the badge. The install location never determines development
status, and the flag does not change the version or authorize publication.

Builds are arm64, ad-hoc signed, and not notarized. A build-only request stops
after artifact verification. An installation request includes replacement and
the scoped cleanup below; perform both without a separate cleanup approval.

### Install and retire old copies

1. For a local install, use the helper's newly built DMG. For a published-release
   install, download that release's DMG and checksum. Verify the checksum, mount
   the image read-only without opening Finder, and stage its app in a unique
   hidden task directory on the `/Applications` filesystem. Verify bundle ID
   `com.tsilva.RepoMan`, version, arm64 architecture and the copied signature.
2. Stop running RepoMan instances, identifying them by their actual executable
   paths rather than a loose process-name match. Replace `/Applications/RepoMan.app`
   with the staged app. Keep the previous installed app in the hidden task
   directory until the replacement launches successfully; do not leave a visible
   `Previous RepoMan.app` beside build artifacts.
3. Launch `/Applications/RepoMan.app` with the user's saved repositories and
   preferences, without `--demo` unless explicitly requested. Confirm that the
   running executable is `/Applications/RepoMan.app/Contents/MacOS/RepoMan`, that
   its hash matches the packaged executable, and that other RepoMan instances
   have stopped. If installation or launch verification fails, restore the
   previous app, preserve diagnostic evidence and stop before deleting old copies.
4. After successful launch, inventory obsolete RepoMan app bundles under this
   checkout's `.build/`, `DerivedData/` and `dist/`, plus the installation backup.
   Inspect each bundle's `Contents/Info.plist` and require the exact RepoMan bundle
   ID before removal. Reject symlinked or escaping paths, tracked files and
   bundles with running executables. Limit cleanup to these verified app bundles
   and older RepoMan installer DMGs with their matching checksum files under `dist/`.
   Keep the installed app, the current verified installer/checksum and any
   explicitly retained artifacts. Skip mounted images and their contents or
   anything of uncertain ownership and report leftovers. Preserve source,
   shared caches, settings, repository data and unrelated apps; do not sweep
   entire build directories.
5. Use `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`
   to unregister each obsolete bundle with `-u` before deleting it. Inspect
   `-dump` for stale RepoMan paths belonging to this checkout or known RepoMan
   installation scratch directories; unregister missing obsolete paths too.
   A hidden backup may never have been registered: an unregister result of
   `-10814` for that verified backup does not block its file cleanup. Report
   other registration failures and still refresh the surviving installed app.
   Delete the verified obsolete bundles and old installer/checksum pairs from
   the inventory, retaining the successful replacement and current artifacts.
   Do not reset the system-wide Launch Services database or clear unrelated
   launcher caches. Force-register the surviving app with
   `lsregister -f /Applications/RepoMan.app`, then run
   `mdimport /Applications/RepoMan.app` to refresh its metadata.
6. Detach the image and remove the successful installation's backup, staging
   directory and disposable task files. Check that obsolete paths are gone,
   query Spotlight with `mdfind "kMDItemCFBundleIdentifier == 'com.tsilva.RepoMan'"`,
   and verify that only the installed copy remains indexed and running. Report
   remaining duplicates or indexing delays accurately instead of claiming they
   were cleared. Do not delete copies outside the scoped directories without
   authorization.
