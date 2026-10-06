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
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
design_dir="$script_dir/../image-assets/dmg"

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

for asset in background.tiff finder-layout.DSStore; do
  if [[ ! -f "$design_dir/$asset" ]]; then
    printf 'DMG design asset not found: %s\n' "$design_dir/$asset" >&2
    exit 1
  fi
done

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/repoman-dmg.XXXXXX")"
temporary_dmg="${output_path}.partial.dmg"
trap 'rm -rf -- "$staging_dir"; rm -f -- "$temporary_dmg"' EXIT

ditto "$app_path" "$staging_dir/RepoMan.app"
ln -s /Applications "$staging_dir/Applications"
mkdir "$staging_dir/.background"
cp "$design_dir/background.tiff" "$staging_dir/.background/background.tiff"
cp "$design_dir/finder-layout.DSStore" "$staging_dir/.DS_Store"
# Keep Finder configuration independent of GUI automation on release runners.
# The saved layout's background alias is relative to the RepoMan volume root.
SetFile -a E "$staging_dir/RepoMan.app"
hdiutil create -quiet -volname RepoMan -fs HFS+ -srcfolder "$staging_dir" -format UDZO "$temporary_dmg"
hdiutil verify -quiet "$temporary_dmg"
mv "$temporary_dmg" "$output_path"
printf 'Created %s\n' "$output_path"
