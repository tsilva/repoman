#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Compile the real app store with a disposable local Git integration harness.
build_dir=".build/parallel-sync-verification"
mkdir -p "$build_dir/sources"
for source in RepoManCore/*.swift RepoMan/*.swift; do
    case "$source" in
        RepoMan/RepoManApp.swift) continue ;;
    esac
    cp "$source" "$build_dir/sources/$(basename "$source")"
done
cp Tools/VerifyParallelSync.swift "$build_dir/sources/VerifyParallelSync.swift"
swiftc -parse-as-library "$build_dir"/sources/*.swift -o "$build_dir/verify"
"$build_dir/verify"
