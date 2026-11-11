#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# No live accounts, monitored repository writes, or persistent preference changes.
build_directory="$PWD/DerivedData/inbox-verification"
mkdir -p "$build_directory"
snapshot_directory="$(mktemp -d "$build_directory/sources.XXXXXX")"
trap 'rm -rf -- "$snapshot_directory"' EXIT
sources=()
capture_directory="${REPOMAN_SCREENSHOT_DIRECTORY:-$PWD/.internal/evidence/inboxes-verification}"
git check-ignore --quiet "$capture_directory/capture.png"
if [[ -n "$(git ls-files -- .internal)" ]]; then
    echo "Private verification storage must not be tracked." >&2
    exit 1
fi
mkdir -p "$capture_directory"
for source in RepoManCore/*.swift RepoMan/*.swift; do
    if [[ "$source" == RepoMan/RepoManApp.swift ]]; then continue; fi
    target="$snapshot_directory/$(basename "$source")"
    cp "$source" "$target"
    sources+=("$target")
done
cp Tools/VerifyInboxes.swift "$snapshot_directory/VerifyInboxes.swift"
xcrun swiftc -parse-as-library -module-name RepoMan \
    -target "$(uname -m)-apple-macos27.0" \
    "${sources[@]}" "$snapshot_directory/VerifyInboxes.swift" -o "$build_directory/verify-inboxes"
REPOMAN_SCREENSHOT_DIRECTORY="$capture_directory" "$build_directory/verify-inboxes" --demo --inboxes
