#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Exercise the real SwiftUI toolbar in a native window, using demo data only.
# Snapshot the sources so concurrent edits cannot invalidate an in-flight check.
build_dir=".build/window-resize-verification"
mkdir -p "$build_dir/sources"
# Remove deleted/renamed source files from earlier snapshots.
rm -f "$build_dir"/sources/*.swift
for source in RepoManCore/*.swift RepoMan/*.swift; do
    case "$source" in
        RepoMan/RepoManApp.swift) continue ;;
    esac
    cp "$source" "$build_dir/sources/$(basename "$source")"
done
cp Tools/VerifyWindowResizing.swift "$build_dir/sources/VerifyWindowResizing.swift"
swiftc -parse-as-library "$build_dir"/sources/*.swift -o "$build_dir/verify"
# Keep the output path out of argv: AppKit treats positional file paths as
# launch documents, which can suppress the initial SwiftUI window.
screenshot_path=""
if [[ "${1:-}" == "--screenshot" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "--screenshot requires an output path" >&2
        exit 1
    fi
    screenshot_path="$2"
    shift 2
fi
REPOMAN_SCREENSHOT_PATH="$screenshot_path" "$build_dir/verify" --demo "$@"
