#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
build_directory="$repo_root/DerivedData/traffic-verification"
mkdir -p "$build_directory"
sources=(RepoManCore/*.swift)
for source in RepoMan/*.swift; do
    if [[ "$source" != RepoMan/RepoManApp.swift ]]; then sources+=("$source"); fi
done
xcrun swiftc -parse-as-library -module-name RepoMan \
    -target "$(uname -m)-apple-macos27.0" \
    "${sources[@]}" Tools/VerifyTrafficOverview.swift -o "$build_directory/verify-traffic"
"$build_directory/verify-traffic" --demo --traffic "$@"
