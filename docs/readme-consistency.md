# Model-backed skill checks

README consistency is the first check using a reusable acceptance-document evaluator. It reads the current root Markdown READMEs and checks the observable rules derived from `optimize-readme`. Findings offer **Run optimize-readme** in the existing repair prompt picker. Submitting a repair is still an explicit user action; verification independently reruns the check afterwards.

In **Settings → Providers**, save an OpenRouter API key in macOS Keychain, test the connection, or remove it. RepoMan does not store the key in preferences, repositories, inspection reports, model inputs, or model caches. The app does not import the key used in development experiments. Demo mode does not save credentials.

Configurable checks display a cog in Settings and in their issue details. The README check defaults to **OpenRouter → DeepSeek V4.1 Flash → Wafer**, with reasoning off. Its cog opens the shared model-check settings sheet. The live catalog lists models and endpoints offering structured outputs. Users can choose an endpoint or OpenRouter routing, and change reasoning when a model requires it. A pinned endpoint has no fallback: failure leaves the semantic review incomplete. New model selections use their default reasoning; restoring defaults restores DeepSeek, Wafer and reasoning off.

## Acceptance and evidence

[The versioned acceptance document](../RepoManCore/Resources/optimize-readme.acceptance.json) owns the rule IDs, conditions, evaluation method and scope. It ships in both the app and Swift package. It is a RepoMan adapter for the installed skill, not a modification of the user's global skill. Keep the conditions in sync when that skill changes and increment the contract version when its meaning changes.

Code checks centered logo references, tagline format and markers, header text links, badge layout, setup/use structure, declared package scripts, architecture placement and local image presence, license links, and declared PyPI image markup. DeepSeek checks the reader-oriented opening and concision. These are the two editorial rules exercised in the model comparison.

The check evaluates present README outcomes. It does not establish whether a skill was previously run, inspect image pixels or architecture fidelity, execute arbitrary commands, verify live links, build package distributions, or reconcile GitHub metadata. README formats other than Markdown remain incomplete. The existing Missing README check owns absent files.

Only README text, repository facts and these root files are eligible for model evidence: `package.json`, `pyproject.toml`, `setup.cfg`, `setup.py`, `Cargo.toml`, `Package.swift`, `go.mod`, and `Makefile`. Environment files and arbitrary source trees are not read for model evidence. READMEs are capped at 64 KiB, selected files at 32 KiB each, combined evidence at 128 KiB, and root READMEs at eight. Paths remain inside the repository, including through symlinks. Credentials/private-key patterns in evidence prevent external review.

The OpenRouter adapter uses strict JSON schemas, requires supported parameters, and limits output to 2,000 tokens. It uses temperature zero when the endpoint supports it. Every semantic verdict includes a rule ID, reason, evidence-document ID and exact contiguous quote; uncertainty may omit its quote. Missing or unexpected rules, incomplete responses, invalid quotes, authentication failures and network errors remain unknown. The model never chooses the aggregate pass/fail result. API error bodies are not displayed or persisted.

## Scheduling and verification

Confirmed mechanical findings remain visible when semantic review is incomplete. An additional incomplete-check row explains the missing evidence or provider error. An incomplete review cannot prove a previous finding absent.

Validated model results are cached by acceptance document, evidence, prompt version, model, provider, reasoning and a credential fingerprint. Clean/violating reviews expire after 24 hours; uncertain reviews after five minutes. The cache stores judgments and excerpts, never the credential, and is restricted to the local user. The ordinary inspection cache cannot skip fresh content reads for this check. Changing model or credential settings invalidates displayed results. A changed README or manifest changes the content key. Evidence changed during an in-flight review remains unknown.

Disabled and ignored checks do not run during background/manual repository scans, avoiding hidden model calls. Display preferences do not suppress independent repair verification. Forced refresh and repair preflight/verification bypass model-result reuse. Reused model results are marked cached and cannot resolve a repair. At most four OpenRouter requests are active, requests have bounded timeouts, and failed requests are not automatically retried within an inspection.

Existing `.repoman.json` exceptions also apply. A README finding subject is, for example, `README.md · tagline.format`; use the exact subject and a nonempty explanation. Exceptions are repository policy, not model instructions.

## Adding another skill check

Add a versioned acceptance document with `skill`, `version`, `scope`, and `rules` containing stable `id`, `title`, `condition`, and `evaluation` fields. Supply bounded `SkillEvidenceDocument` values and implement the skill-specific mechanical validators. Use `SkillConsistencyEvaluator` for semantic rules and translate its decisions into the normal repository findings. Register a configurable `RepositoryCheck` and its repair recipe. The evaluator, OpenRouter adapter, secure credential storage, catalog and settings sheet are shared; they contain no README-specific judgment logic.

The focused tests cover a second unrelated skill, evidence/rule validation, cache persistence and invalidation, mechanical failures observed in the model trials, partial results, disabled calls, fresh repair verification, pinned routing and credential-safe API errors.

## Local OpenRouter test key

Normal `swift test` runs use fake credentials and mocked model responses. Repair-queue tests inject an offline check catalog, so preflight and verification never read the app's Keychain key or make model calls.

To save a separate test key, run `bash Tools/setup-openrouter-test-key.sh` from this checkout. The hidden prompt saves it in `.openrouter-test-key`, ignored by Git and readable only by your user. The app does not read this file. Alternatively, provide `OPENROUTER_TEST_API_KEY` in the test environment (including an Xcode Test scheme); the environment variable takes precedence.

The optional live test makes one `GET /api/v1/key` authentication request, with no model generation and no repository content. Having a key configured does not enable it. Run it explicitly with:

```sh
REPOMAN_RUN_OPENROUTER_TESTS=1 swift test --filter OpenRouterLiveTests
```

No live inference test is enabled by this setup. Never commit a real key or place it in a fixture.
