# Model-backed skill checks

README consistency is the first check using a reusable acceptance-document evaluator. It reads the current root Markdown READMEs and checks the observable rules derived from `optimize-readme`. Findings offer **Repair README consistency** in the existing repair prompt picker. The prompt includes the bundled acceptance conditions and requires no installed skill. Submitting a repair is still an explicit user action; verification independently reruns the check afterwards.

README reviews default to **Codex → GPT-6.1 Sol**, with low reasoning, using the same private RepoMan Codex login as repairs and commit messages. No OpenRouter key is required. Existing model preferences from before service selection also adopt Codex. If RepoMan is signed out, the incomplete-check details include its Codex sign-in command.

Configurable checks display a cog in Settings and in their issue details. The shared settings sheet selects **Codex (default)** or **OpenRouter**; restoring defaults selects Codex. Codex reviews use an ephemeral chat with a read-only permission profile, disabled tools and repository instructions, and an isolated temporary working directory. The agent receives only the supplied acceptance contract and evidence and cannot repair files during inspection.

OpenRouter remains optional. In **Settings → Providers**, save its API key in macOS Keychain, test the connection, or remove it. Only checks explicitly selecting OpenRouter use it. RepoMan does not store the key in preferences, repositories, inspection reports, model inputs, or model caches, and does not import the key used in development experiments. Demo mode does not save credentials. The optional OpenRouter service initially selects **DeepSeek V4.1 Flash → Wafer**, with reasoning off; its catalog offers compatible structured-output models and endpoints. A pinned endpoint has no fallback, and unavailable endpoints leave reviews incomplete.

## Acceptance and evidence

[The versioned acceptance document](../RepoManCore/Resources/optimize-readme.acceptance.json) owns the rule IDs, conditions, evaluation method and scope. It ships in both the app and Swift package, and supplies the requirements embedded in the repair prompt. It is self-contained; the originating skill does not need to be installed. Increment the contract version when its meaning changes.

Code checks centered logo references, tagline format and markers, header text links, badge layout, setup/use structure, declared package scripts, architecture placement and local image presence, license links, and declared PyPI image markup. The selected model checks the reader-oriented opening and concision. These are the two editorial rules exercised in the model comparison.

The check evaluates present README outcomes. It does not establish whether a skill was previously run, inspect image pixels or architecture fidelity, execute arbitrary commands, verify live links, build package distributions, or reconcile GitHub metadata. README formats other than Markdown remain incomplete. The existing Missing README check owns absent files.

Only README text, repository facts and these root files are eligible for model evidence: `package.json`, `pyproject.toml`, `setup.cfg`, `setup.py`, `Cargo.toml`, `Package.swift`, `go.mod`, and `Makefile`. Environment files and arbitrary source trees are not read for model evidence. READMEs are capped at 64 KiB, selected files at 32 KiB each, combined evidence at 128 KiB, and root READMEs at eight. Paths remain inside the repository, including through symlinks. Credentials/private-key patterns in evidence prevent external review.

Both adapters use the same strict JSON schema and acceptance instructions. Codex uses the shared structured-task runner, with a 60-second deadline and bounded responses. The optional OpenRouter adapter requires supported parameters, limits output to 2,000 tokens, and uses temperature zero when the endpoint supports it. Every semantic verdict includes a rule ID, reason, evidence-document ID and exact contiguous quote; uncertainty may omit its quote. Missing or unexpected rules, incomplete responses, invalid quotes, authentication failures and network errors remain unknown. The model never chooses the aggregate pass/fail result. API error bodies are not displayed or persisted.

## Scheduling and verification

Confirmed mechanical findings remain visible when semantic review is incomplete. An additional incomplete-check row explains the missing evidence or provider error. An incomplete review cannot prove a previous finding absent.

Validated model results are cached by acceptance document, evidence, prompt version, service, model, provider, reasoning and either RepoMan Codex login-file metadata or an OpenRouter credential fingerprint. Login/logout invalidates Codex cache reuse without reading credentials. Clean/violating reviews expire after 24 hours; uncertain reviews after five minutes. The cache stores judgments and excerpts, never the credential, and is restricted to the local user. The ordinary inspection cache cannot skip fresh content reads for this check. Changing model or credential settings invalidates displayed results. A changed README or manifest changes the content key. Evidence changed during an in-flight review remains unknown.

Disabled and ignored checks do not run during background/manual repository scans, avoiding hidden model calls. Display preferences do not suppress independent repair verification. Forced refresh and repair preflight/verification bypass model-result reuse. Reused model results are marked cached and cannot resolve a repair. At most four Codex reviews or four OpenRouter requests are active, requests have bounded timeouts, and failed requests are not automatically retried within an inspection.

Existing `.repoman.json` exceptions also apply. A README finding subject is, for example, `README.md · tagline.format`; use the exact subject and a nonempty explanation. Exceptions are repository policy, not model instructions.

## Adding another skill check

Add a versioned acceptance document with `skill`, `version`, `scope`, and `rules` containing stable `id`, `title`, `condition`, and `evaluation` fields. Supply bounded `SkillEvidenceDocument` values and implement the skill-specific mechanical validators. Use `SkillConsistencyEvaluator` for semantic rules and translate its decisions into the normal repository findings. Register a configurable `RepositoryCheck` and its repair recipe. The evaluator, Codex structured-task runner, optional OpenRouter adapter, secure credential storage, catalog and settings sheet are shared; they contain no README-specific judgment logic.

The focused tests cover a second unrelated skill, evidence/rule validation, cache persistence and invalidation, mechanical failures observed in the model trials, partial results, disabled calls, fresh repair verification, pinned routing and credential-safe API errors.

## Local OpenRouter test key

Normal `swift test` runs use fake credentials and mocked model responses or a local mock Codex protocol process. Repair-queue tests inject an offline check catalog, so preflight and verification never read the app's Keychain key or make model calls.

To save a separate test key, run `bash Tools/setup-openrouter-test-key.sh` from this checkout. The hidden prompt saves it in `.openrouter-test-key`, ignored by Git and readable only by your user. The app does not read this file. Alternatively, provide `OPENROUTER_TEST_API_KEY` in the test environment (including an Xcode Test scheme); the environment variable takes precedence.

The optional live test makes one `GET /api/v1/key` authentication request, with no model generation and no repository content. Having a key configured does not enable it. Run it explicitly with:

```sh
REPOMAN_RUN_OPENROUTER_TESTS=1 swift test --filter OpenRouterLiveTests
```

No live inference test is enabled by this setup. Never commit a real key or place it in a fixture.
