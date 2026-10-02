#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Exercise the real SwiftUI toolbar in a native window, using demo data only.
# Snapshot the sources so concurrent edits cannot invalidate an in-flight check.
build_dir=".build/window-resize-verification"
mkdir -p "$build_dir/sources"
for source in RepoManCore/*.swift RepoMan/*.swift; do
    case "$source" in
        RepoMan/RepoManApp.swift) continue ;;
    esac
    cp "$source" "$build_dir/sources/$(basename "$source")"
done
cp Tools/VerifyWindowResizing.swift "$build_dir/sources/VerifyWindowResizing.swift"
swiftc -parse-as-library "$build_dir"/sources/*.swift -o "$build_dir/verify"
"$build_dir/verify" --demo
