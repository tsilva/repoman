# Repository manifest

Use one optional root `.repoman.json` for repository identity, production websites
and repository check policy. Repositories using only defaults need no file.
The manifest is data, never executable configuration. Other tools can read its
identity fields without installing RepoMan.

```json
{
  "version": 1,
  "short-name": "example",
  "tagline": "Build and ship with confidence",
  "github-url": "https://example.com/",
  "websites": {
    "example.tsilva.eu": {
      "url": "https://example.tsilva.eu/",
      "ga4-expectation": "required",
      "sentry-expectation": "required"
    }
  },
  "ci": {
    "components": [
      {"path": ".", "ecosystem": "javascript", "requires": ["test", "build"]}
    ]
  }
}
```

- `version`: `1`; older policy-only files may omit it.
- `short-name`: optional repository label matching `[A-Za-z0-9_-]{1,20}` for chat
  titles and skill prefixes. It never changes Git identity, paths or remotes.
- `tagline`, `github-url`: expected README and GitHub About metadata.
  JSON `"github-url": null` requires an empty GitHub Website field; omitting the
  key leaves that check inapplicable.
- `vercel-project-id`, `websites`: explicit production project binding, domain
  inventory and telemetry policies. An empty `websites` object declares no custom
  domains. See [website checks](website-checks.md).
- `ci`, `exceptions`, `stashAgeDays`, `maximumTrackedFileBytes`, `notebooks`:
  existing check requirements and preferences. See [check policy](additional-checks.md#repository-configuration).

Exception reasons and recorded website observations remain explicit data. A
recorded observation does not replace live verification. Unknown policy fields,
invalid values and duplicate JSON keys leave checks incomplete.

## Migrating older manifests

RepoMan temporarily supports missing metadata through legacy `.repoman.yaml`
and `.repo-metadata.toml` readers. Explicit JSON values take precedence, including
`null` and an empty website inventory. Malformed JSON never triggers fallback.
New and migrated repositories should contain only `.repoman.json`.

After synchronizing the selected checkout and reviewing its instructions, preview:

```sh
python3 Tools/migrate-manifests.py --repo /path/to/repository
```

Apply with an independent backup directory outside the selected repositories:

```sh
python3 Tools/migrate-manifests.py --repo /path/to/repository --apply --backup-dir /path/to/backups
```

Repeat `--repo` for explicitly selected repositories. The Python 3.11+ helper
supports the historical scalar/block-mapping YAML subset. It rejects conflicts,
unknown TOML fields, duplicate keys, unsafe files and changed inputs. Existing
check policy, reasons, short names, URLs, telemetry policy and observation dates
are preserved. Legacy domains become website entries; disagreeing domain
inventories require review. Original bytes and a hash receipt are saved before
replacement; legacy files are removed only after successful JSON readback.
The helper changes no branches, index entries, commits or remotes.
