#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 0 ]]; then
  printf 'Usage: bash %s\nValidate the committed main release in GitHub Actions without publishing.\n' "$0" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
cd "$repo_root"
git fetch origin main --tags
release_sha="$(git rev-parse origin/main)"
repository="$(gh repo view --json nameWithOwner --jq '.nameWithOwner')"
gh workflow run release.yml --repo "$repository" --ref main -f ref="$release_sha"
printf 'Dispatched release validation for %s at %s; uncommitted work is excluded.\n' "$repository" "$release_sha"
printf 'Follow the workflow_dispatch run for this SHA; validation does not publish.\n'
