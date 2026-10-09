# Model-backed skill checks

README consistency is the first check using a reusable acceptance-document evaluator. It reads the current root Markdown READMEs and checks the observable rules derived from `optimize-readme`. Findings offer **Repair README consistency** in the existing repair prompt picker. The prompt includes the bundled acceptance conditions and requires no installed skill. Submitting a repair is still an explicit user action; verification independently reruns the check afterwards.

README reviews default to **Codex → GPT-6.1 Sol** with low reasoning through AgentBridge. Existing model preferences are retained. Configure `AGENTBRIDGE_BASE_URL` (default `http://127.0.0.1:8082/api/v1`) and, when gateway authentication is enabled, save its token in **Settings → Providers**. Upstream provider credentials and Codex authentication belong to AgentBridge. An unreachable gateway leaves semantic review incomplete while mechanical findings remain visible.

Configurable checks display a cog in Settings and in their issue details. The shared settings sheet selects the model family, model, provider preference, and reasoning. Both Codex and OpenRouter selections use the same AgentBridge client and endpoint. Restoring defaults selects Codex. The agent receives only the supplied acceptance contract and evidence and cannot repair files during inspection.

The OpenRouter model family initially selects **DeepSeek V4.1 Flash → Wafer** with reasoning off; its catalog offers compatible structured-output models and endpoints through AgentBridge’s metadata routes. A pinned endpoint has no fallback, and unavailable endpoints leave reviews incomplete. Gateway tokens stay in Keychain and never enter preferences, repositories, inspection reports, model inputs, or caches. Demo mode does not save credentials.

## Acceptance and evidence

[The versioned acceptance document](../RepoManCore/Resources/optimize-readme.acceptance.json) owns the rule IDs, conditions, evaluation method and scope. It ships in both the app and Swift package, and supplies the requirements embedded in the repair prompt. It is self-contained; the originating skill does not need to be installed. Increment the contract version when its meaning changes.

Code checks centered logo references, tagline format and markers, header text links, badge layout, setup/use structure, declared package scripts, architecture placement and local image presence, license links, and declared PyPI image markup. The selected model checks the reader-oriented opening and concision. These are the two editorial rules exercised in the model comparison.

The check evaluates present README outcomes. It does not establish whether a skill was previously run, inspect image pixels or architecture fidelity, execute arbitrary commands, verify live links, build package distributions, or reconcile GitHub metadata. README formats other than Markdown remain incomplete. The existing Missing README check owns absent files.

Only README text, repository facts and these root files are eligible for model evidence: `package.json`, `pyproject.toml`, `setup.cfg`, `setup.py`, `Cargo.toml`, `Package.swift`, `go.mod`, and `Makefile`. Environment files and arbitrary source trees are not read for model evidence. READMEs are capped at 64 KiB, selected files at 32 KiB each, combined evidence at 128 KiB, and root READMEs at eight. Paths remain inside the repository, including through symlinks. Credentials/private-key patterns in evidence prevent external review.

Both model families use the same gateway transport, strict JSON schema, and acceptance instructions. Requests have a 660-second timeout. The OpenRouter model family requires supported parameters, limits output to 2,000 tokens, and uses temperature zero when the endpoint supports it. Every semantic verdict includes a rule ID, reason, evidence-document ID and exact contiguous quote; uncertainty may omit its quote. Missing or unexpected rules, incomplete responses, invalid quotes, authentication failures and network errors remain unknown. The model never chooses the aggregate pass/fail result. API error bodies are not displayed or persisted.

## Scheduling and verification

Confirmed mechanical findings remain visible when semantic review is incomplete. An additional incomplete-check row explains the missing evidence or provider error. An incomplete review cannot prove a previous finding absent.

Validated model results are cached by acceptance document, evidence, prompt version, service, model, provider, reasoning and gateway endpoint and credential fingerprints. Clean/violating reviews expire after 24 hours; uncertain reviews after five minutes. The cache stores judgments and excerpts, never the credential, and is restricted to the local user. The ordinary inspection cache cannot skip fresh content reads for this check. Changing model or credential settings invalidates displayed results. A changed README or manifest changes the content key. Evidence changed during an in-flight review remains unknown.

Disabled and ignored checks do not run during background/manual repository scans, avoiding hidden model calls. Display preferences do not suppress independent repair verification. Forced refresh and repair preflight/verification bypass model-result reuse. Reused model results are marked cached and cannot resolve a repair. At most four model reviews are active, requests have bounded timeouts, and failed requests are not automatically retried within an inspection.

Existing `.repoman.json` exceptions also apply. A README finding subject is, for example, `README.md · tagline.format`; use the exact subject and a nonempty explanation. Exceptions are repository policy, not model instructions.

## Adding another skill check

Add a versioned acceptance document with `skill`, `version`, `scope`, and `rules` containing stable `id`, `title`, `condition`, and `evaluation` fields. Supply bounded `SkillEvidenceDocument` values and implement the skill-specific mechanical validators. Use `SkillConsistencyEvaluator` for semantic rules and translate its decisions into the normal repository findings. Register a configurable `RepositoryCheck` and its repair recipe. The evaluator, AgentBridge client, secure gateway credential storage, catalog and settings sheet are shared; they contain no README-specific judgment logic.

The focused tests cover a second unrelated skill, evidence/rule validation, cache persistence and invalidation, mechanical failures observed in the model trials, partial results, disabled calls, fresh repair verification, pinned routing and credential-safe API errors.

## Gateway connectivity tests

Normal `swift test` runs use synthetic credentials and mocked model responses. Repair-queue tests inject an offline check catalog, so preflight and verification never read the app’s Keychain token or make model calls.

The opt-in connectivity test makes one AgentBridge capabilities request, with no model generation or repository content. Set `AGENTBRIDGE_BASE_URL` to the gateway API root and optionally `AGENTBRIDGE_API_KEY`, then run:

```sh
REPOMAN_RUN_AGENTBRIDGE_TESTS=1 swift test --filter OpenRouterLiveTests
```

Upstream test-key files and provider-key environment variables are no longer read. Never commit a real token or place it in a fixture.
