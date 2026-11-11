# Repository branding

The dashboard and CLI share two local checks. `branding.assets` checks required files and the README image reference. `branding.provenance` checks the recorded generation and derivation history against the files in the working tree. Both use tracked paths. Local edits to tracked files are visible in the results.

Both checks skip repositories whose checkout name or configured GitHub repository name starts with `private-` or `sandbox-`, ignoring case. The exemption uses the name and requires no GitHub visibility lookup.

| Repository type | Required assets |
| --- | --- |
| Every non-exempt repository | Root `logo.png` referenced as an image in its tracked root README |
| Website or web app | A browser favicon (ICO, PNG, or SVG) and an Open Graph preview (PNG, JPEG, or WebP, at least 600 × 315 and approximately 1.91:1). Prefer a 1200 × 630 preview. |
| Apple app | An app icon PNG from the Xcode app-icon catalog or Icon Composer asset |
| Android app | A launcher icon PNG or WebP |
| Other packaged desktop app | An app icon in ICO, ICNS, or PNG format |

Profiles are cumulative. RepoMan detects web projects from website metadata, tracked Next.js, Astro, Svelte, Nuxt, Vercel and Netlify configuration, and root, public or source HTML entrypoints. It recognizes Apple app targets in Xcode projects, app icon catalogs, and Icon Composer projects, Android manifests with a launcher category, and Tauri or Electron Builder configuration. Use `profiles` in the record below for a nonstandard layout. The values are `web`, `apple`, `android`, and `desktop`. A project can declare additional profiles without disabling detected ones. For an intentional exception, use [the repository exception mechanism](additional-checks.md).

A same-repository GitHub raw URL to the root `logo.png` also satisfies the README reference, which supports READMEs rendered by package registries. RepoMan checks the URL structure locally.

README findings distinguish an absent root logo, invalid PNG data or file type, an untracked logo, an incorrect declaration path, and a tracked logo the README does not reference. An inspection failure leaves coverage incomplete.

RepoMan accepts conventional web asset paths in the root, `app/`, `public/`, `static/`, `www/`, or the shared workflow's `image-assets/web-seo/` pack. For an alternate layout, put the actual application or web export path in the record. Keep one primary export per required role. Use the shared branding skill to verify additional ICO frames and platform variants, and verify web metadata and platform build wiring where the assets are consumed. These local checks cover the representative tracked files. Live asset delivery, every application target, and visual quality require separate verification.

## Recording ImageGen provenance

Keep the untouched generation output so its original Content Credentials can be inspected. Save a tracked `image-assets/provenance.json` alongside the export manifest. This example shows the structure. Compute each real file digest with `shasum -a 256 PATH` after derivation and placement.

```json
{
  "version": 1,
  "profiles": [],
  "sources": [
    {
      "path": "image-assets/sources/logo-source.png",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "model": "gpt-image-2.5-sunburst-2026-09-08",
      "generatedAt": "2026-11-03T12:00:00Z",
      "evidence": "Generation receipt or validated Content Credentials reference"
    }
  ],
  "exports": [
    {
      "role": "readme-logo",
      "path": "logo.png",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "source": "image-assets/sources/logo-source.png"
    }
  ]
}
```

Use the role names `readme-logo`, `favicon`, `social-preview`, `apple-icon`, `android-icon`, and `desktop-icon`. Each export's `source` names an original in the same record. Multiple exports can share a source. The checked-in baseline is GPT Image 2.5 Sunburst. Record the exact model or snapshot only when the generation tool or independently validated provider evidence identifies it. Omit unknown `model`, `generatedAt`, or `evidence` values. In particular, a generic `gpt-image` label, a mutable `chatgpt-image-latest` alias, or a commit date cannot establish a model version. Keep evidence references free of credentials and private conversation content.

A changed SHA-256, missing file, undeclared source, or a recorded model outside the baseline is a finding. Missing records, role lineage, or generation evidence leave provenance incomplete. When the record is absent, RepoMan fingerprints up to eight tracked `logo-source.png`, `icon-source.png`, and `social-source.png` files under `sources/` directories. It reports embedded PNG Content Credentials data as an unverified lead. RepoMan verifies the record and hashes locally. The origin claim comes from the recorded receipt, so assess the receipt and validate any Content Credentials independently before relying on the claim. Review the output at its intended sizes before accepting it.

```sh
repoman check --repo /path/to/repository --check branding.assets --check branding.provenance --format json
```
