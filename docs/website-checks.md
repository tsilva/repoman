# Production website checks

RepoMan checks production `tsilva.eu` websites through three shared dashboard and CLI checks:

| ID | Purpose |
| --- | --- |
| `website.domains` | Discover assigned production domains and report domains missing from repository metadata. |
| `website.sentry` | Observe live Sentry initialization and ordinary collection responses. |
| `website.analytics` | Observe live Google Analytics initialization and ordinary collection responses. |

## Domain coverage

An authenticated Vercel CLI is required to establish domain coverage. RepoMan enumerates every accessible team, paginates its projects and assigned domains, and matches GitHub project links to the monitored repository's remote. For CLI-created projects without a Git link it uses the root `.vercel/project.json` project ID. It never guesses from folder or project names. Projects absent from `latestDeployments` are included; branch and custom-environment domains are excluded. An assigned domain can still be offline, redirected, or protected; assignment alone does not establish a healthy deployment. Missing access, invalid responses and pagination limits keep coverage incomplete.

Use a root `.repoman.yaml` to record production URLs and the latest telemetry evidence for each site:

```yaml
version: 1
websites:
  example.tsilva.eu:
    url: https://example.tsilva.eu/
    ga4: tag-detected
    ga4-expectation: required
    ga4-verification-path: /pricing
    sentry: unverified
    sentry-expectation: required
    sentry-verification-path: /
    checked-on: 2026-11-03
  www.example.tsilva.eu:
    url: https://www.example.tsilva.eu/
    redirect-to: https://example.tsilva.eu/
    ga4-expectation: disabled
    ga4-exception-reason: Redirect alias. GA4 is checked on the destination.
    sentry-expectation: disabled
    sentry-exception-reason: Redirect alias. Sentry is checked on the destination.
    checked-on: 2026-11-03
```

Use a block mapping with at most 32 unique lowercase hostnames under `tsilva.eu`, including the apex. Each `url` must be the HTTPS root for its hostname. A redirect can point to another HTTPS root in the same manifest. Use `websites: {}` for an explicitly empty inventory. Optional `ga4` and `sentry` values describe dated observations. `accepted` records a successful collection response, `observed` records a request with no visible response, `tag-detected` records a live loader or initialization signal, `source-detected` records initialization code at the serving revision, and `unverified` records inconclusive evidence. Optional `availability` records `reachable`, `unavailable` or `unverified`. Use `checked-on` for the observation date. RepoMan evaluates live collection separately from these recorded values.

Set `ga4-expectation` and `sentry-expectation` to `required`, `optional` or `disabled`. Both services default to `required` and use their respective `*-verification-path`, which defaults to `/`. Use a same-site path starting with one slash. Path segments may contain letters, digits, periods, underscores, tildes and hyphens. Queries, fragments and traversal segments are invalid. RepoMan skips automatic verification for `optional` and `disabled` services and records their required `*-exception-reason` in the report. Use `optional` when telemetry may be present and `disabled` when the site is expected to omit it. Existing domain-specific exceptions in `.repoman.json` take precedence. Domain inventory still includes sites with telemetry exceptions.

When `.repoman.yaml` is absent, RepoMan accepts the legacy top-level `domains` array in `.repo-metadata.toml`. Keep existing short names there for tools that use repository identity metadata. Invalid website metadata keeps the check incomplete. RepoMan inspects discovered domains even when the manifest omits them, and `website.domains` reports the omission. When Vercel inventory fails, RepoMan still inspects declared domains and reports incomplete discovery. Unmapped projects and projects without a monitored checkout remain outside the dashboard's repository list. The standalone inventory reports those gaps.

## Live evidence

A bounded HTTPS request checks the verification page before an isolated, nonpersistent native WebKit probe observes ordinary client activity for up to 20 seconds after load, with a 35-second total browser deadline. Services share a visit when their hostname and verification path match. At most four probes run across repository inspections. No saved browser sessions, credentials or consent overrides are used. Top-level redirects must stay within the repository's declared or discovered HTTPS domains. The probe never calls SDK capture, flush or test-event methods; ordinary page visits may generate the site's normal telemetry.

A check passes only when ordinary collection receives a successful response. Explicit collection failures and disabled clients produce findings. SDK configuration alone, queued beacons without response evidence, denied consent, consent banners, silent clients, server-only SDKs, unsupported custom tunnels, authentication, network failures and unavailable evidence remain **incomplete**, never passed. Sentry's normal event/session/transaction envelopes and supported SDK transport callbacks can provide collection evidence. A successful response from an arbitrary proxy is not upstream Sentry proof. Google Tag Manager or Vercel Web Analytics alone does not prove GA4 collection.

Successful ingestion responses establish transport acceptance, not dashboard indexing, retention, correct property/project ownership, or complete error/route coverage. RepoMan does not query Sentry project settings or Google Analytics reporting APIs. Use the separate `audit-vercel-ga-sentry` skill for a deeper account/source/browser audit. Missing initialization on a landing page remains unverified because it can also mean delayed, server-only, consent-gated or unsupported instrumentation.

Account inventory and passive probe results are cached in memory for up to five minutes. A changed verification path or domain set prevents reuse of an earlier probe. Explicit dashboard refresh invalidates inventory and bypasses passive probe caches. Fresh CLI runs bypass probe caches. Responses, DSNs, measurement IDs, payloads and provider diagnostics are not persisted or shown in findings. Website availability and Cloudflare proxy checks remain retired.

## Commands and exceptions

```sh
repoman check --repo /path/to/repository --check website.domains --remote --format json
repoman check --repo /path/to/repository --check website.sentry --check website.analytics --remote --format json
```

All three checks require `--remote` in the CLI and are skipped in local-only runs. Incomplete evidence exits `3` when no actionable finding exists; findings exit `1` even when other domains are incomplete. Settings exposes each check separately. Domain-specific `.repoman.json` exceptions use the check ID and bare domain as subject, for example:

```json
{"version":1,"exceptions":{"website.sentry":{"example.tsilva.eu":"Intentional server-only reporting; checked separately"}}}
```

Exceptions skip that service's probe when no other selected service needs it and appear in the report. They do not remove domains from inventory coverage. Existing `website.sentry` and `website.analytics` exceptions become active again; old availability and Cloudflare exceptions remain inert.

## Standalone Vercel domain inventory

The read-only inventory compares assigned `tsilva.eu` domains in accessible Vercel teams with local root metadata and reports unmapped projects:

```sh
python3 Tools/audit-vercel-domains.py --root /path/to/repositories
python3 Tools/audit-vercel-domains.py --root /path/to/repositories --team team-slug --json
```

Requires Python 3.11+, Git, and an authenticated Vercel CLI. It reads assigned project domains, including older deployments absent from `latestDeployments`; it does not edit files or request environment values. Exit codes: `0` means all inventory domains are declared, `1` means coverage gaps, and `2` means the inventory could not be completed. This standalone tool inventories assigned domains, including branch assignments; the dashboard restricts automatic discovery to Production.

References: [Vercel projects API](https://vercel.com/docs/rest-api), [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview/), [Google Analytics setup verification](https://developers.google.com/analytics/devguides/collection/ga4/troubleshoot).
