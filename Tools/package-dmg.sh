#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s /path/to/RepoMan.app /path/to/RepoMan.dmg\n' "$0" >&2
  exit 2
fi

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'DMG packaging requires macOS.\n' >&2
  exit 1
fi

app_path="$1"
output_path="$2"

if [[ ! -d "$app_path" || ! -f "$app_path/Contents/Info.plist" ]]; then
  printf 'App bundle not found: %s\n' "$app_path" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"
output_path="$(cd "$(dirname "$output_path")" && pwd)/$(basename "$output_path")"
if [[ -e "$output_path" ]]; then
  printf 'Output already exists: %s\n' "$output_path" >&2
  exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/repoman-dmg.XXXXXX")"
temporary_dmg="${output_path}.partial.dmg"
trap 'rm -rf -- "$staging_dir"; rm -f -- "$temporary_dmg"' EXIT

ditto "$app_path" "$staging_dir/RepoMan.app"
ln -s /Applications "$staging_dir/Applications"
hdiutil create -quiet -volname RepoMan -srcfolder "$staging_dir" -format UDZO "$temporary_dmg"
hdiutil verify -quiet "$temporary_dmg"
mv "$temporary_dmg" "$output_path"
printf 'Created %s\n' "$output_path"
