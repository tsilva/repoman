# Website checks

Declare each assigned production hostname in the repository-root `.repo-metadata.toml`. This extends the same file used for repository display metadata; existing `short-name` and other fields remain valid.

```toml
short-name = "example"
domains = ["example.tsilva.eu"]
```

The top-level `domains` array opts the repository into four independent checks. No file or an empty array disables them. Use bare hostnames, including every canonical redirect destination. For example, the CV repository declares `cv.tsilva.eu`, `tsilva.eu`, and `www.tsilva.eu`. The reader supports quoted hostnames, comments, and multiline arrays. Duplicate, malformed, or unsupported values make the check unavailable. It accepts at most 32 hostnames, restricted to `tsilva.eu` and its subdomains; schemes, paths, ports, wildcards, and unrelated hosts are rejected.

| Check | Evidence |
| --- | --- |
| `website.online` | The declared HTTPS root returns a 2xx status with valid TLS. DNS, connection, TLS, non-2xx responses and redirects outside declared HTTPS domains are issues. A successful landing page does not certify every route or backend. |
| `website.sentry` | Setup is confirmed by an enabled runtime client with a DSN, including bundled versioned scopes and legacy hubs. Delivery passes when an ordinary event, transaction, or session envelope sent by the live page receives a 2xx response. Confirmed setup without delivery produces an informational **Sentry delivery unverified** finding with a verification preset. Rejected delivery or an explicitly disabled client is an issue. |
| `website.analytics` | A live Google Analytics GA4 collection request receives a 2xx response. A detected Google tag, Tag Manager, or queued beacon without a successful response produces an informational **Google Analytics delivery unverified** finding with a verification preset. A loader alone does not confirm client initialization or delivery. Vercel Analytics does not satisfy this check. |
| `website.cloudflare` | The requested domain's HTTPS response contains Cloudflare's `CF-Ray` header. Evidence is retained from the original redirect response rather than inferred from its destination. An unreachable domain without response evidence remains unverified. |

Each check appears in Issues and Settings and has a repair preset. The probes share one visit per domain per inspection. Repository refresh reads metadata, makes HTTPS requests, and visits public landing pages in isolated WebKit views; it does not change monitored files, deployments, or DNS. The HTTPS request has 10-second request and 15-second resource timeouts and reads at most 2 MiB. Browser inspection samples once per second for up to 20 seconds after loading, with an overall 35-second bound, and finishes early when both services return successful collection responses. This allows delayed SDK imports to finish. At most four repository checks run concurrently, as before.

Browser visits use ephemeral storage without existing logins. They observe the site's own telemetry requests and may count as ordinary pageviews or sessions. They do not send synthetic errors, accept consent, authenticate, or retain request URLs, event payloads, measurement IDs, DSNs, or tokens. Network hooks preserve the original fetch promise, XHR operation, and beacon return value. Same-origin Sentry tunnels are recognized when the request exposes a normal envelope body; opaque bodies, custom wrappers, server-only SDKs, protected pages, and consent gates can remain unverified. No silent browser visit can prove downstream dashboard processing from an ingestion response alone. The **Send Sentry test event** and **Send Google Analytics test event** presets authorize one labelled synthetic event per reported domain per agent turn. New preset chats expose `test_website_delivery`, hosted by RepoMan itself, so the agent does not need a separate browser runtime. It uses the loaded SDK, respects consent and disabled clients, and records only a response correlated with the test token. Sentry sends an informational message; GA sends `repoman_delivery_check` with `debug_mode`. These can appear in production telemetry. A queued beacon or SDK flush is not acceptance, and a 2xx response does not prove downstream dashboard receipt. Opaque transports and unsupported SDK wrappers remain unverified.

Synthetic test results are recorded in the repair conversation. Sentry lifecycle callbacks observe the actual SDK transport response even when native fetch bypasses window hooks. A correlated accepted test also stores credential-free structured proof, valid for five minutes and bound to the repository, service and declared domain set. The repair resolves when a fresh inspection confirms silent, enabled setup; a fresh failure, disabled client, changed metadata, cached result or expired proof cannot be overridden. Dashboard processing is reported separately and does not require user input to complete ingestion verification. Ordinary background inspection remains passive. Existing chats created before these presets cannot acquire the new tool on resume; start a new delivery-test session. Inspect the exact deployed source and verify the correct project's dashboard when needed.

In a delivery-test chat, a plain follow-up such as `try again` preserves the selected preset and permits one test per reported domain in the new turn. Chats affected by earlier retries that cleared the saved preset recover their scope from the original explicit test authorization and matching issue type. A chat without that authorization remains ineligible; domain checks and consent restrictions still apply on every retry.

Background probes can reuse observations for five minutes (connection/browser failures retry after one minute). Metadata is reread before choosing a cached probe; changing the domain set invalidates its observations. Manual and repair inspections bypass these cached observations, and cached or incomplete results cannot verify a repair. Per-domain exceptions use the existing reasoned `.repoman.json` mechanism:

```json
{
  "version": 1,
  "exceptions": {
    "website.sentry": {
      "example.tsilva.eu": "Sentry is intentionally server-only; dashboard verification is maintained separately."
    }
  }
}
```

## Vercel domain inventory

The read-only tool compares every assigned `tsilva.eu` domain in each accessible Vercel team with local root metadata:

```sh
python3 Tools/audit-vercel-domains.py --root /path/to/repositories
python3 Tools/audit-vercel-domains.py --root /path/to/repositories --team team-slug --json
```

Requires Python 3.11+, Git, and an authenticated Vercel CLI. It matches GitHub project links against repository remotes, or uses a matching `.vercel/project.json` for CLI-created projects without a Git link. Ambiguous or unmapped projects are reported rather than assigned by folder name. Linked worktrees are excluded. The tool reads assigned project domains, including older deployments absent from `latestDeployments`; it does not request environment values or read authentication files. Exit codes: `0` means all inventory domains are declared, `1` means coverage gaps, and `2` means the inventory could not be completed.

The app's regular refresh checks only declared domains. Run this inventory again after adding or reassigning Vercel domains to find metadata gaps; it does not edit files automatically.

Detection references: [Cloudflare response headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/), [Google Analytics setup verification](https://developers.google.com/analytics/devguides/collection/ga4/troubleshoot).
