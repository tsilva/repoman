# Additional repository checks

README consistency also supports reusable model-backed acceptance rules. Configure AgentBridge in **Settings → Providers** and use the check's cog to select its model and provider. See [model-backed skill checks](readme-consistency.md) for scope, evidence, caching and repair verification.

RepoMan registers twenty-three additional detectors in the existing Issues, Settings, repair composer and verification workflow. Refresh reads files, Git metadata and GitHub metadata and fetches remote-tracking refs. It does not install packages, execute scripts or notebook cells, mutate monitored files, apply stashes, change branches, or publish anything. Selecting a repair preset only fills the composer; sending it explicitly starts agent work.

## Detectors

| ID | Check | Evidence and scope |
| --- | --- | --- |
| `dependencies.manager` | Package-manager mismatch | JavaScript `packageManager` versions, competing lockfiles, and recognizable CI installation commands. A root project with no declared manager is reported for review. Installs in other working directories and global tool installs are skipped. |
| `dependencies.safeguards` | Dependency safeguards missing | npm age and lifecycle-script settings; pnpm workspace age and exotic dependency blocking, plus pnpm 10 `.npmrc` compatibility settings; Bun repository-owned `install.minimumReleaseAge >= 604800` seconds, age exclusions, lifecycle-script suppression (`install.ignoreScripts` or `.npmrc`) and CI overrides; effective uv cutoff and bad-package constraints; tracked pip constraint references. |
| `dependencies.lockfile` | Missing or untracked lockfile | Dependency manifests without a matching Git-tracked lockfile in their directory or workspace ancestors. Git-staged lockfiles count as tracked; the ordinary uncommitted-change check still applies. |
| `dependencies.sources` | Dependency exceptions need review | Direct URL/Git/path dependencies, custom indexes and dependency age exclusions. Ordinary registry dependencies and explicit `workspace` references are exempt. Configuration credentials are never included in evidence. |
| `ci.mutableActions` | Actions references are mutable | External actions and reusable workflows without full commit hashes, or Docker actions without SHA-256 digests. Local actions are skipped. |
| `ci.suppressedFailures` | Validation failures are suppressed | Recognizable validation commands in jobs/steps with `continue-on-error: true`, or commands using failure suppression. Optional diagnostics without recognizable validation commands are skipped. This is a conservative configuration check, not shell control-flow analysis. |
| `files.generatedTracked` | Generated files tracked | Tracked dependency directories, Python bytecode/caches, `.venv`, Xcode DerivedData, and `.DS_Store`. Ignore rules alone do not remove tracked entries. Each path has its own finding. |
| `git.oldStashes` | Old stashes | Stashes at least 30 days old, showing their commit hash and up to ten affected paths, including untracked paths. Identity uses the commit hash, not the changing stash index. |
| `git.unfinishedOperation` | Git operation unfinished | Unmerged index entries; merge, rebase/am, cherry-pick, revert or sequencer markers; detached HEAD. Inspection works with Git-managed separate Git directories and linked checkouts. |
| `github.description` | GitHub description drift | The actual GitHub description compared with the marked README tagline from the latest published default-branch commit. Local or feature-branch README edits do not influence it. |
| `github.privateVisibility` | Private repository visibility | GitHub remote repository names starting with `private-` (case-insensitive) must have `PRIVATE` visibility. `PUBLIC` and `INTERNAL` produce a blocked finding, identified by `owner/repository`. Uses the remote name rather than the local folder name. Other names and non-GitHub remotes are skipped. |
| `docs.brokenLinks` | Broken local documentation links | Markdown inline/reference links, HTML image/link references, and relative skill references in root AGENTS.md. Checks root README variants, AGENTS.md, tracked SKILL.md files and tracked Markdown under docs/. Resolves paths relative to each document and decodes percent-encoded filenames. Skips external URLs, site-root routes, fragments, inline/fenced/indented code examples and HTML comments. Backticked skill paths in AGENTS.md are inspected as actual instruction references. |
| `notebooks.hygiene` | Notebook hygiene | Saved error outputs or serialized outputs exceeding 256 KiB in tracked nbformat 4 notebooks. Repository opt-in is required, because teaching notebooks may deliberately contain errors and large outputs. Cells are never executed. |
| `git.unpublishedBranches` | Unpublished branch work | Commits on inactive local branches unreachable from all fetched remote branches. Branches checked out in any worktree are excluded. Identity is the full local branch ref. No remotes means skipped; absent remote refs and failed fetches remain unavailable. Patch-equivalent, rebased or squash-merged work still needs review. |
| `git.upstream` | Missing or deleted upstream | The current branch has no upstream despite configured remotes, or a local branch's configured upstream ref is absent. Intentionally local branches are legitimate, so missing upstreams are informational. Identity is the full branch ref. Failed fetches cannot resolve findings. |
| `files.secrets` | Potential tracked secrets | High-confidence private-key headers and GitHub, AWS, Slack, Stripe live and Hugging Face credential shapes in current tracked UTF-8 files, including staged files. Evidence includes only path, type and line number, never values or fragments. Binary files are skipped. Does not scan history, stashes, untracked files or every provider. Removing a finding does not establish revocation; intentional fixtures can have path exceptions. |
| `dependencies.lockfileDrift` | Manifest and lockfile disagree | Static comparisons of npm v2/v3 package declarations, pnpm v9 importer specifiers, Bun text lockfile v0/v1 workspace declarations (regular, dev, optional and peer dependencies), and simple uv v1 direct dependency metadata, including tracked workspace manifests. No resolver runs. Unsupported managers/schemas, binary `bun.lockb`, catalogs, pnpm peer auto-install behavior, Python extras/markers/groups/custom sources and dynamic metadata remain unavailable. Missing lockfiles cannot verify synchronization. Evidence never includes dependency values or authenticated URLs. |
| `dependencies.runtime` | Runtime version mismatch | Incompatible numeric Node/Python constraints across manifests, ancestor version files, `.tool-versions`, adjacent Dockerfiles and root CI setup actions. Supports simple selectors, inequalities, caret and compatible-release constraints. CI variants are not compared to each other; multiple CI versions are judged against manifest support constraints. Aliases, prereleases, OR/exclusion ranges and dynamic matrices remain unavailable. |
| `ci.security` | Risky Actions workflow | Direct interpolation of recognizable untrusted event fields into run scripts, workflow-wide token writes, any `write-all` permissions, or `pull_request_target` checking out PR code. Block jobs/steps and static block/flow permissions are supported. Environment assignments, specific job-scoped writes and shell text resembling YAML are not flagged. This is configuration review, not full data-flow analysis. |
| `files.oversized` | Oversized tracked files | Regular tracked files larger than `maximumTrackedFileBytes` (default 10 MiB). Reads metadata rather than contents or history. Intentional assets can have path exceptions. |
| `git.checkoutIntegrity` | Broken submodule or LFS checkout | Index gitlinks with missing checkouts or unexpected HEAD commits, and exact LFS pointers remaining in files with `filter=lfs`. Does not run LFS filters, recurse submodules, download content or inspect submodule working changes. Intentional partial checkouts and submodule updates can have path exceptions. |
| `files.mergeMarkers` | Merge markers left in files | Complete opening/separator/closing conflict blocks in tracked text, including diff3 and custom marker lengths. Skips Markdown, reStructuredText, AsciiDoc and notebooks to preserve instructional examples. Ordinary divider lines are ignored; source fixtures can have path exceptions. |
| `files.projectReferences` | Broken project references | Missing npm/pnpm/uv workspace members, local Actions/workflows, explicit script invocations, setup-action version files and package entry points. Honors workspace exclusions, known generated entry-point directories and ignore rules. Dynamic paths, shell directory changes affecting references, escaping paths and unsupported patterns remain unavailable. Commands are never executed. |

Dependency inspection includes root manifests and tracked nested manifests, inheriting ancestor settings and lockfiles. The readers support common block YAML, scalar TOML, multiline arrays, inline TOML tables and npm key/value configuration. They are conservative recognizers rather than complete package-manager, TOML, YAML or shell interpreters. Unsupported syntax, dynamic working directories/failure policies, unreadable files, escaping symlinks, malformed notebook formats and exceeded limits produce **unavailable**, never proof that a previous finding was fixed. Workstation configuration cannot substitute for repository-owned safeguards.

The uv reader honors `uv.toml` over `[tool.uv]` at the same directory level. A fixed cutoff older than seven days also satisfies the age check. pnpm settings are interpreted according to the declared version: pnpm 10 needs the compatibility `.npmrc` settings in addition to workspace settings. Intentional lifecycle scripts, libraries without lockfiles, GPU indexes and teaching outputs should be recorded as reasoned exceptions.

## Repository configuration

An optional root `.repoman.json` controls new-check thresholds and precise exceptions. The existing Ignore Check action and global Settings toggles also remain available as display preferences.

```json
{
  "version": 1,
  "stashAgeDays": 60,
  "maximumTrackedFileBytes": 10485760,
  "notebooks": {
    "enabled": true,
    "maximumOutputBytes": 262144
  },
  "exceptions": {
    "dependencies.lockfile": {
      "pyproject.toml": "This library intentionally tests fresh dependency resolution."
    },
    "dependencies.sources": {
      "pyproject.toml": "The documented GPU wheel index is approved for this project."
    },
    "notebooks.hygiene": {
      "lessons/expected-error.ipynb": "This lesson demonstrates the exception intentionally."
    }
  }
}
```

Exceptions map a check ID and exact finding subject to a nonempty reason; subjects are matched literally and wildcards do not expand. No executable configuration is accepted. Manifest, documentation, notebook and generated-file subjects are repository-relative paths. Workflow subjects are `.github/workflows/<name>.yml`. Stash subjects are full stash commit hashes. Branch health subjects are full `refs/heads/<branch>` refs. Checkout-integrity subjects are repository-relative paths. Runtime and lockfile-drift subjects are manifest paths. Project-reference subjects are manifest or workflow paths. Git operation subjects are `conflicts`, `HEAD`, or the Git marker name. Metadata subjects are `owner/repository`.

Changing a repository exception changes the detector's policy, and can verify a finding as absent under that policy. Global display toggles and Ignore Check do not change verification. Inspect the recorded reason when reviewing a policy-based resolution.

Unknown configuration fields, unsupported versions, empty exception reasons and out-of-range thresholds make the new checks unavailable. `stashAgeDays` accepts 1–3650; notebook output limits accept 1024–8388608 bytes. `maximumTrackedFileBytes` accepts 1024–1073741824 bytes (default 10485760). Missing fields retain defaults; notebook checks default to disabled until a repository opts in.

## Published metadata

The visibility check uses a separate read-only GraphQL query with the existing GitHub CLI login, so it works without a README or a published default branch. Background refresh may reuse visibility for ten minutes, keyed by remote owner/repository; cached absence cannot verify a repair. Repair preflight and verification read fresh visibility. Missing visibility, authentication failures and API errors remain unavailable. Refresh never changes visibility. The repair recipe verifies the destination and administrator access, reviews GitHub Pages and fork consequences, changes only its visibility to private, and verifies the result.

The metadata check uses the installed GitHub CLI and its existing login. A read-only GraphQL request discovers the actual root README filename; a second request returns the description and that README together from the latest default-branch commit. All root README variants recognized by RepoMan are supported. Repositories without README files or tagline markers are skipped. It does not copy credentials or change descriptions during refresh.

Tagline validation follows the existing push-sync header contract: exactly one marker pair, after the logo in the opening centered paragraph, containing one plain-text `<strong>` element. Invalid markers or unsupported HTML entities remain unavailable. The normalized tagline must be nonempty and at most 350 Unicode code points. Authentication failures, API errors, binary/unreadable READMEs and missing default branches cannot resolve existing metadata findings. Description repair checks access and changes only the destination description; it does not push or alter Actions automation.

## Inspection bounds

Checks continue to run off the UI actor in batches of at most four, sharing bounded file and Git reads within an inspection. Normal text files are limited to 1 MiB and the shared text cache to 32 MiB. Notebook files allow at most 8 MiB each, 32 MiB total, and 250 tracked notebooks. Git output is capped at 2 MiB, matching tracked paths at 20000 (Git path filters avoid enumerating unrelated source files), manifests at 64, documentation files at 100, and workflow directory entries at 200. Stash inspection permits at most 100 stashes and 20 old stashes. Excesses remain unavailable and preserve prior unresolved conversations.

Read-only Git commands disable optional index writes and fsmonitor hooks and external diff/textconv helpers, time out after ten seconds and terminate with a bounded kill fallback. GitHub reads use the existing 15-second timeout and 2 MiB response limit. Inspection findings are cached by the existing refresh reports; changing selection does not rerun these checks. Automatic checks across all repositories run once at startup; later refreshes are explicit. Ordinary refresh reuses GitHub description metadata for at most ten minutes, keyed by the actual remote owner/repository, to limit API traffic across large repository collections. Repair preflight and verification always bypass that cache. Reports explicitly track cached checks, and cached absence cannot resolve an earlier issue during ordinary refresh.

All-tracked-file checks share the 20000-path bound. Binary/text detection reads at most an 8 KiB sample per uncached file, with a separate shared 32 MiB sampling budget; decoded text still shares the 32 MiB cache. Oversized text, missing tracked files, escaping symlinks and unreadable files remain unavailable. Branch inspection permits at most 64 local branches. Workspace/reference expansion allows at most 256 visits, eight levels and 200 directory entries per read.

Refresh fetches every configured remote, even without a current-branch upstream, and prunes deleted remote-tracking branches. Explicit refspecs and an empty configured refmap restrict writes to `refs/remotes/<remote>/`; local branches and tags are preserved, including repositories with mirror-style fetch configuration. Submodule recursion is disabled. At most sixteen remotes are fetched sequentially within the existing shared 45-second deadline per repository. Any failure keeps remote-dependent findings unavailable.

Bun text lockfiles are read as JSONC, including comments and trailing commas. Bun safeguards use configuration beside the selected lockfile, or the workspace install root when no lockfile exists; standalone nested projects do not borrow unrelated ancestor policy. Bun’s built-in trusted-package list still permits some dependency lifecycle scripts, so the check requires explicit script suppression or a documented exception. Global workstation configuration is not inspected. These are static declaration checks; they do not resolve packages or validate the entire transitive graph. See [Bun configuration](https://bun.sh/docs/runtime/bunfig), [lifecycle scripts](https://bun.sh/docs/pm/lifecycle), and [text lockfiles](https://bun.sh/blog/bun-lock-text-lockfile).
