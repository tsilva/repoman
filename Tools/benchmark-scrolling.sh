#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Snapshot sources so edits in another chat cannot invalidate an in-flight build.
build_dir=".build/scrolling-benchmark"
mkdir -p "$build_dir/sources"
for source in RepoManCore/*.swift RepoMan/*.swift; do
    case "$source" in
        RepoMan/RepoManApp.swift|RepoMan/RepositoryStore.swift) continue ;;
    esac
    cp "$source" "$build_dir/sources/$(basename "$source")"
done
cat RepoMan/RepositoryStore.swift Tools/BenchmarkScrolling.swift > "$build_dir/sources/RepositoryStore.swift"
swiftc -O -whole-module-optimization -num-threads 4 -parse-as-library \
    "$build_dir"/sources/*.swift -o "$build_dir/benchmark-scrolling"
"$build_dir/benchmark-scrolling" --demo
