#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Snapshot sources so concurrent edits do not invalidate the build.
mkdir -p .build
build_dir="$(mktemp -d "$PWD/.build/traffic-scrolling.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
mkdir -p "$build_dir/sources"
for source in RepoManCore/*.swift RepoMan/*.swift; do
    case "$source" in
        RepoMan/RepoManApp.swift|RepoMan/WebsiteTrafficStore.swift) continue ;;
    esac
    cp "$source" "$build_dir/sources/$(basename "$source")"
done
cat RepoMan/WebsiteTrafficStore.swift Tools/BenchmarkTrafficScrolling.swift > "$build_dir/sources/WebsiteTrafficStore.swift"
xcrun swiftc -O -whole-module-optimization -num-threads 4 -parse-as-library \
    -target "$(uname -m)-apple-macos27.0" \
    "$build_dir"/sources/*.swift -o "$build_dir/benchmark-traffic"
"$build_dir/benchmark-traffic" "$@"
