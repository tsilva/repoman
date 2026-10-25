# Website audits outside RepoMan

RepoMan no longer probes website availability, Sentry, Google Analytics or Cloudflare, and has no embedded browser. Existing domain metadata can remain for other tools. The personal `audit-vercel-ga-sentry` skill handles separately requested GA/Sentry audits; it does not replace uptime or Cloudflare monitoring. Removing these detectors reduces dashboard coverage explicitly rather than treating retired checks as passed. Old website exceptions are inert and may be removed from `.repoman.json` when convenient.

The standalone inventory below remains available independently of the dashboard.

## Vercel domain inventory

The read-only tool compares every assigned `tsilva.eu` domain in each accessible Vercel team with local root metadata:

```sh
python3 Tools/audit-vercel-domains.py --root /path/to/repositories
python3 Tools/audit-vercel-domains.py --root /path/to/repositories --team team-slug --json
```

Requires Python 3.11+, Git, and an authenticated Vercel CLI. It matches GitHub project links against repository remotes, or uses a matching `.vercel/project.json` for CLI-created projects without a Git link. Ambiguous or unmapped projects are reported rather than assigned by folder name. Linked worktrees are excluded. The tool reads assigned project domains, including older deployments absent from `latestDeployments`; it does not request environment values or read authentication files. Exit codes: `0` means all inventory domains are declared, `1` means coverage gaps, and `2` means the inventory could not be completed.

The app's regular refresh checks only declared domains. Run this inventory again after adding or reassigning Vercel domains to find metadata gaps; it does not edit files automatically.

Detection references: [Cloudflare response headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/), [Google Analytics setup verification](https://developers.google.com/analytics/devguides/collection/ga4/troubleshoot).
