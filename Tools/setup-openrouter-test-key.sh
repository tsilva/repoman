#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
umask 077
read -r -s -p 'OpenRouter test key (hidden): ' test_key </dev/tty
printf '\n' >/dev/tty
case "$test_key" in
    sk-or-*) ;;
    *) printf 'Expected an OpenRouter API key. Nothing was saved.\n' >&2; exit 1 ;;
esac
if [[ ${#test_key} -gt 512 || "$test_key" =~ [[:space:]] ]]; then
    printf 'Invalid key. Nothing was saved.\n' >&2
    exit 1
fi
key_temp="$(mktemp "$repo_root/.openrouter-test-key.XXXXXX")"
trap 'rm -f "$key_temp"; unset test_key' EXIT
printf '%s\n' "$test_key" >"$key_temp"
mv -f "$key_temp" "$repo_root/.openrouter-test-key"
printf 'Saved the local test key with owner-only permissions. No API call was made.\n'
