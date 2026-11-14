# Production website checks

RepoMan checks public production websites through shared dashboard and CLI checks:

| ID | Purpose |
| --- | --- |
| `website.domains` | Report public Vercel projects without an assigned production `tsilva.eu` domain and assigned `tsilva.eu` domains missing from repository metadata. |
| `website.sitemap` | Check `/sitemap.xml` on mapped production `tsilva.eu` domains for public GitHub repositories. |
| `website.sitemapSubmission` | Check whether verified production sitemap URLs were submitted under `sc-domain:tsilva.eu` in Google Search Console. |
| `website.lighthouseCI` | Check whether each mapped production `tsilva.eu` hostname has Lighthouse CI configured in GitHub Actions. |
| `website.sentry` | Observe live Sentry initialization and ordinary collection responses. |
| `website.analytics` | Observe live Google Analytics initialization and ordinary collection responses. |

## Domain coverage

An authenticated Vercel CLI is required to establish domain coverage. RepoMan enumerates accessible teams, paginates their projects and production domain assignments, and matches GitHub project links to the monitored repository's remote. For projects without a Git link, set the top-level `vercel-project-id` in `.repoman.json` or use an existing `.vercel/project.json` link. Both IDs must agree when present. RepoMan never guesses from folder or project names. Projects absent from `latestDeployments` are included. Branch domains, custom environments and explicitly unverified assignments are excluded. Missing access, invalid responses and pagination limits keep coverage incomplete.

When a mapped project has no production `tsilva.eu` assignment, RepoMan checks its assigned production `vercel.app` aliases and other verified production hostnames. A successful anonymous HTTPS response within that project confirms public access and triggers one missing-domain finding per project. Protected or unreachable URLs leave public access unverified. Both GA4 and Sentry are required on these fallback URLs by default. Once Vercel assigns a production `tsilva.eu` domain, RepoMan uses that domain for telemetry. A manifest can contain only the project binding with `"websites": {}` while the custom domain is pending.

Use a root `.repoman.json` to record production URLs and the latest telemetry evidence for each site:

```json
{
  "version": 1,
  "websites": {
    "example.tsilva.eu": {
      "url": "https://example.tsilva.eu/",
      "ga4": "tag-detected",
      "ga4-expectation": "required",
      "ga4-verification-path": "/pricing",
      "sentry": "unverified",
      "sentry-expectation": "required",
      "sentry-verification-path": "/",
      "checked-on": "2026-11-03"
    },
    "www.example.tsilva.eu": {
      "url": "https://www.example.tsilva.eu/",
      "redirect-to": "https://example.tsilva.eu/",
      "ga4-expectation": "disabled",
      "ga4-exception-reason": "Redirect alias. GA4 is checked on the destination.",
      "sentry-expectation": "disabled",
      "sentry-exception-reason": "Redirect alias. Sentry is checked on the destination.",
      "checked-on": "2026-11-03"
    }
  }
}
```

Use a block mapping with at most 32 unique lowercase hostnames under `tsilva.eu`, including the apex. Each `url` must be the HTTPS root for its hostname. A redirect can point to another HTTPS root in the same manifest. Use `"websites": {}` for an explicitly empty inventory. Optional `ga4` and `sentry` values describe dated observations. `accepted` records a successful collection response, `observed` records a request with no visible response, `tag-detected` records a live loader or initialization signal, `source-detected` records initialization code at the serving revision, and `unverified` records inconclusive evidence. Optional `availability` records `reachable`, `unavailable` or `unverified`. Use `checked-on` for the observation date. RepoMan evaluates live collection separately from these recorded values.

Set `ga4-expectation` and `sentry-expectation` to `required`, `optional` or `disabled`. Both services default to `required` and use their respective `*-verification-path`, which defaults to `/`. Use a same-site path starting with one slash. Path segments may contain letters, digits, periods, underscores, tildes and hyphens. Queries, fragments and traversal segments are invalid. RepoMan skips automatic verification for `optional` and `disabled` services and records their required `*-exception-reason` in the report. Use `optional` when telemetry may be present and `disabled` when the site is expected to omit it. Existing domain-specific exceptions in `.repoman.json` take precedence. Domain inventory still includes sites with telemetry exceptions.

The root `.repoman.json` is the shared manifest for website inventory, repository identity and check policy. Store an optional `short-name` there for naming tools. During transition, missing JSON fields can still be read from legacy `.repoman.yaml` and `.repo-metadata.toml` files; migrated repositories use only JSON. Invalid website metadata keeps the check incomplete. RepoMan inspects discovered domains even when the manifest omits them, and `website.domains` reports the omission. When Vercel inventory fails, RepoMan still inspects declared domains and reports incomplete discovery. Unmapped projects and projects without a monitored checkout remain outside the dashboard's repository list. The standalone inventory reports those gaps.

## Live evidence

The sitemap check uses the repository's GitHub remote to verify public visibility and sends an anonymous HTTPS request to `/sitemap.xml` on each mapped `tsilva.eu` host. It accepts a well-formed XML document with a Sitemap `urlset` or `sitemapindex` root and the standard namespace. HTTP 404, 410 and HTTP 200 responses without a sitemap document produce findings. Unverified repository visibility, blocked redirects, other HTTP errors and responses exceeding 2 MiB leave the check incomplete. Redirects stay within the repository's mapped `tsilva.eu` hosts. This check uses no browser and does not crawl the URLs listed in the sitemap. See the [Sitemaps protocol](https://www.sitemaps.org/protocol.html).

A bounded HTTPS request checks the verification page before an isolated, nonpersistent native WebKit probe observes ordinary client activity for up to 20 seconds after load, with a 35-second total browser deadline. Services share a visit when their hostname and verification path match. At most four probes run across repository inspections. No saved browser sessions, credentials or consent overrides are used. Top-level redirects must stay within the repository's declared or discovered HTTPS domains. The probe never calls SDK capture, flush or test-event methods; ordinary page visits may generate the site's normal telemetry.

A check passes only when ordinary collection receives a successful response. Explicit collection failures and disabled clients produce findings. SDK configuration alone, queued beacons without response evidence, denied consent, consent banners, silent clients, server-only SDKs, unsupported custom tunnels, authentication, network failures and unavailable evidence remain **incomplete**, never passed. Sentry's normal event/session/transaction envelopes and supported SDK transport callbacks can provide collection evidence. A successful response from an arbitrary proxy is not upstream Sentry proof. Google Tag Manager or Vercel Web Analytics alone does not prove GA4 collection.

Successful ingestion responses establish transport acceptance, not dashboard indexing, retention, correct property/project ownership, or complete error/route coverage. The website checks do not query Sentry project settings or Google Analytics reporting APIs. For a deeper production Vercel audit, use `$private-skills_audit-vercel-ga4` for Google Analytics or `$private-skills_audit-vercel-sentry` for Sentry. Missing initialization on a landing page remains unverified because it can also mean delayed, server-only, consent-gated or unsupported instrumentation.

Account inventory and passive probe results are cached in memory for up to five minutes. A changed verification path or domain set prevents reuse of an earlier probe. Explicit dashboard refresh invalidates inventory and bypasses passive probe caches. Fresh CLI runs bypass probe caches. Responses, DSNs, measurement IDs, payloads and provider diagnostics are not persisted or shown in findings. Website availability and Cloudflare proxy checks remain retired.

## Lighthouse CI coverage

RepoMan reads `.github/workflows/*.yml` and `.github/workflows/*.yaml` in the monitored GitHub checkout. It recognizes the shared `tsilva/.github` Lighthouse workflow and the [Treosh Lighthouse CI action](https://github.com/treosh/lighthouse-ci-action), matching explicit HTTPS audit targets to their hostnames. A supported direct [`lhci autorun` command](https://github.com/GoogleChrome/lighthouse-ci) or a Treosh step without explicit URLs counts as build-level setup for a repository with one production hostname. With multiple hostnames, RepoMan needs explicit audit targets to attribute coverage. Dynamic targets and unsupported workflow syntax leave unmatched coverage incomplete.

The check reports each uncovered hostname separately and supports hostname exceptions for intentional redirect aliases. It inspects local workflow definitions without visiting sites or checking published workflow state, run history, or audit scores. Custom wrappers are outside automatic recognition.

## Commands and exceptions

```sh
repoman check --repo /path/to/repository --check website.domains --remote --format json
repoman check --repo /path/to/repository --check website.sitemap --remote --format json
repoman check --repo /path/to/repository --check website.sitemapSubmission --remote --format json
repoman check --repo /path/to/repository --check website.lighthouseCI --remote --format json
repoman check --repo /path/to/repository --check website.sentry --check website.analytics --remote --format json
```

All website checks require `--remote` in the CLI and are skipped in local-only runs. Incomplete evidence exits `3` when no actionable finding exists; findings exit `1` even when other domains are incomplete. Settings exposes each check separately. Domain-specific `.repoman.json` exceptions use the check ID and bare domain as subject, for example:

```json
{"version":1,"exceptions":{"website.sentry":{"example.tsilva.eu":"Intentional server-only reporting; checked separately"}}}
```

Exceptions skip that service's probe when no other selected service needs it and appear in the report. They do not remove domains from inventory coverage. Existing `website.sentry` and `website.analytics` exceptions become active again; old availability and Cloudflare exceptions remain inert.

## Google Analytics traffic in the macOS app

RepoMan can sort repositories by GA4 active users over the last seven complete calendar days in the property's time zone and over the last 30 minutes. Both counts measure distinct users over the full window. Traffic metrics appear in the **Traffic** view; repository sidebar rows show GitHub and Git status without traffic figures. These counts are independent of the collection check and never create repository findings.

All traffic reports exclude activity geolocated to Portugal (`countryId = PT`) before aggregation, including repository counts, Realtime, overview totals, comparison periods, daily charts, channels and landing pages. Hostname and stream restrictions still apply. This report-only exclusion also applies to historical periods and leaves collected GA4 data unchanged. It excludes genuine Portuguese visitors as well as the owner's visits; VPNs and unknown locations can still leave personal activity in the reports. See the [GA4 historical dimensions](https://developers.google.com/analytics/devguides/reporting/data/v1/api-schema) and [Realtime dimensions](https://developers.google.com/analytics/devguides/reporting/data/v1/realtime-api-schema).

RepoMan does not identify or subtract Lighthouse visits from already collected reports. The shared `tsilva/.github` Lighthouse CI workflow blocks Google Tag Manager and Google Analytics network requests during audits to prevent collection. Audits using other configurations or run before that blocking was enabled may still be present. GA4's [automatic known-bot exclusion](https://support.google.com/analytics/answer/9888366) does not provide a Lighthouse-specific guarantee.

The **Traffic** toolbar tab opens a portfolio overview using the same approved historical reader and local website bindings. Choose 7, 30 (the default), or 90 complete calendar days and optionally compare the preceding equal-length period. The view shows sessions, pageviews, engagement, coverage, daily sessions, and a sortable website table with full-window active users and sparklines. Click a website row to load its top five session channels and landing pages. Selecting a repository in the sidebar returns to its inspection view. The overview fits the available pane width and uses the dashboard’s thin, trackless vertical scrollbar, without horizontal scrolling.

The overview reads all configured website bindings, independently of sidebar search or whether their repositories are currently selected. It requires explicit production `hostnames`; it does not infer domains or silently use unfiltered property totals. Each hostname is a separate row, with identical property/hostname bindings deduplicated. Conflicting property mappings for the same hostname remain unavailable until corrected. Coverage describes this configured inventory, not every live domain in a hosting account. An unconfigured website requires a reviewed property grant, reader allowlist entry, and local binding before it can be reported.

Portfolio totals and the chart include only fresh, successful reports. Coverage includes successful zero-traffic reports and excludes stale or unavailable reports. Engagement is summed engaged sessions divided by summed sessions; active users are distinct over the entire selected period per hostname and are not summed into a portfolio user total. Percentage change is unavailable when the prior value is zero; a site with new sessions displays **New** instead of an infinite percentage. Dates use each property's time zone, and the chart aligns comparison periods by day offset. Properties with different time zones therefore have different day boundaries. GA4 consent, blocking, collection gaps, reporting delays and later revisions still apply.

The Traffic view refreshes historical reports hourly while open, with four concurrent site readers and a 35-second timeout per reader invocation. Each site needs three `runReport` requests: current aggregate, previous aggregate, and both periods' daily sessions. Breakdowns add two requests only when opened. A successful empty single-period report means zero; rejected, truncated, thresholded or sampled reports remain unavailable. Failed refreshes preserve the last good row with a stale label, exclude it from fresh portfolio totals, and retry after five minutes. Changing period keeps separate in-memory caches. The toolbar refresh button bypasses the cache; loading does not clear the existing table. Closing the view stops scheduled polling; reopening reuses its cache and refreshes due results. Closing the app discards that cache.

The app never renews credentials or retrieves keys. For unattended reporting on a Mac with the reviewed broker and existing approved `ga4-reporting` and `ga4-realtime` profiles, run `python3 Tools/install-traffic-renewal.py --check`, then the same command without `--check`. This explicitly installs two user LaunchAgents that invoke the trusted broker's one-shot `refresh` command at login and at minutes 0, 10, 20, 30, 40, and 50. Calendar scheduling catches up missed renewals on wake. Tokens retain their approved 15-minute lifetime and read-only permissions; no reader routes, property grants, credentials or broker metadata are copied into RepoMan. The installer refuses changed existing job definitions and does not approve profiles.

The jobs run independently of RepoMan, so hourly reports and one-minute Realtime refreshes can continue without manual token renewal. They do not hold the broker's profile lock between renewals, allowing ad hoc approved reporting. A failed renewal exits without opening login prompts or choosing another credential source; the next scheduled run retries. Revoked or expired Google/Infisical logins still need their normal sign-in procedure. Failed readers preserve stale values as described above. Inspect operation and expiry with `infisical-token-broker status ga4-reporting` or `status ga4-realtime`; sanitized broker output is in `~/Library/Logs/RepoMan/`. Keep these jobs active when finishing ordinary report batches; their standing purpose is automatic renewal, rather than a temporary per-chat lease.

The installed job labels are `com.tsilva.RepoMan.token-renewal.ga4-reporting` and `com.tsilva.RepoMan.token-renewal.ga4-realtime`. To disable automatic renewal, explicitly stop each with `launchctl bootout gui/$(id -u)/LABEL` and remove its matching plist from `~/Library/LaunchAgents/`; then deactivate the relevant broker profile when no reports are running. Re-running the installer is idempotent. Run `PYTHONDONTWRITEBYTECODE=1 python3 Tools/test_traffic_renewal.py` for credential-free installation tests. See [Apple's scheduling behaviour](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html), [GA4 data freshness](https://support.google.com/analytics/answer/11198161) and [Data API quotas](https://developers.google.com/analytics/devguides/reporting/data/v1/quotas).

For a credential-free native-window and cache-state check on macOS 27 with Xcode installed, run `bash Tools/verify-traffic-overview.sh`. It uses synthetic reports and temporary fixtures, verifies cache preservation on failure and period changes, and exits automatically. Set `REPOMAN_SCREENSHOT_DIRECTORY` to an existing ignored output directory to capture the normal and minimum window sizes. The optional `--live` flag additionally exercises the configured approved reader; renew its access through the approved reporting procedure first. It prints coverage and elapsed time, without report values or provider diagnostics. Use `--demo --traffic` when launching the development app to preview the view with illustrative data. Command-R refreshes traffic when that tab is active.

Create `~/Library/Application Support/RepoMan/analytics.json` with local, reviewed bindings. Keys are lowercase GitHub `owner/repository` identities taken from the checkout's Git remote. The reader paths must be absolute and point to approved, read-only executables.

```json
{
  "reportReader": "/absolute/path/to/approved/ga4/report",
  "realtimeReader": "/absolute/path/to/approved/ga4/realtime-report",
  "repositories": {
    "owner/example": {
      "propertyId": "123456789",
      "hostnames": ["example.tsilva.eu"],
      "streamIds": ["9876543210"]
    }
  }
}
```

Set `hostnames` to the site's production hostnames when it shares a property. The seven-day report filters on those hostnames together, so a visitor counted on two aliases contributes one active user. For a shared property, set `streamIds` to streams dedicated to the site for its Realtime count. RepoMan leaves the live count unavailable for a hostname-scoped site with no stream mapping. Omit both filters to show property-wide counts for a dedicated property.

Both executables accept `--request-json PROPERTY_ID`, read the corresponding GA4 Data API request on stdin, and return the raw GA4 report JSON on stdout. The historical reader calls `runReport`. The Realtime reader calls `runRealtimeReport` with the default 30-minute window. Readers must accept the Portugal exclusion combined with the hostname or stream filter in an `andGroup`; validators that accept only a bare stream filter need this narrowly scoped compatibility update. An existing launcher restricted to `runReport` works as `reportReader`; omit `realtimeReader` until its separate approved route is available. The readers own property allowlists and authentication. Configure or renew access outside the app through the approved credential broker.

RepoMan checks for updates in the background. It reuses seven-day results for one hour and Realtime results for one minute. **Refresh All** also requests fresh data when a traffic refresh is idle. A dash indicates unavailable data, zero indicates a successful report with no active users, and a tilde marks a stale value. Hover over the counts to see the last successful fetch time.

## Search Console access

`website.sitemapSubmission` compares the final HTTPS URL of each verified live XML sitemap with the URLs submitted under `sc-domain:tsilva.eu`. Redirect aliases that resolve to the same sitemap share a result within the repository. A successful inventory without the exact sitemap URL produces a missing submission finding. Missing access, an invalid response, or an unverified live sitemap leaves coverage incomplete. Submission under another property and discovery through `robots.txt` are outside this check. See the [Search Console sitemap report](https://support.google.com/webmasters/answer/7451001).

Each dashboard refresh or CLI invocation makes at most one Search Console list request, on demand after it verifies a live sitemap. Dashboard scans share the result across repositories, including failures.

Configure an approved read-only reader with an absolute executable path. For the CLI, set `REPOMAN_SEARCH_CONSOLE_READER`. For the dashboard, set `defaults write com.tsilva.RepoMan searchConsoleReaderPath -string /absolute/path/to/reader` and relaunch. RepoMan passes one argument, the fixed Google API URL `https://www.googleapis.com/webmasters/v3/sites/sc-domain%3Atsilva.eu/sitemaps`. The reader owns authentication and must perform one GET with the `https://www.googleapis.com/auth/webmasters.readonly` scope. Its stdout must be a JSON object with an integer `status` and the upstream JSON `body`, for example `{"status":200,"body":{"sitemap":[{"path":"https://example.tsilva.eu/sitemap.xml"}]}}`. An empty successful inventory is valid. RepoMan bounds reader execution and suppresses its diagnostics. Keep credentials in the approved broker and return only the response. See the [Google Sitemaps list API](https://developers.google.com/webmaster-tools/v1/sitemaps/list).

## Standalone Vercel domain inventory

The read-only inventory compares assigned `tsilva.eu` domains in accessible Vercel teams with local root metadata and reports unmapped projects:

```sh
python3 Tools/audit-vercel-domains.py --root /path/to/repositories
python3 Tools/audit-vercel-domains.py --root /path/to/repositories --team team-slug --json
```

Requires Python 3.11+, Git, and an authenticated Vercel CLI. It reads assigned project domains, including older deployments absent from `latestDeployments`; it does not edit files or request environment values. Exit codes: `0` means all inventory domains are declared, `1` means coverage gaps, and `2` means the inventory could not be completed. This standalone tool inventories assigned domains, including branch assignments; the dashboard restricts automatic discovery to Production.

References: [Vercel projects API](https://vercel.com/docs/rest-api), [Apple WKWebView](https://developer.apple.com/documentation/webkit/wkwebview/), [Google Analytics setup verification](https://developers.google.com/analytics/devguides/collection/ga4/troubleshoot).
