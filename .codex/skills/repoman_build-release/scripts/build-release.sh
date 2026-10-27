#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [--version X.Y.Z] [--output-dir DIR]\n' "$0" >&2
}

version=''
output_dir=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      version="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      output_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$script_dir" rev-parse --show-toplevel)"
cd "$repo_root"

[[ "$(uname -s)" == Darwin ]] || { printf 'A macOS host is required.\n' >&2; exit 1; }
xcode_version="$(xcodebuild -version)"
[[ "$xcode_version" == "Xcode 27."* ]] || { printf 'Xcode 27 is required.\n' >&2; exit 1; }

if [[ -z "$version" ]]; then
  version="$(xcodebuild -project RepoMan.xcodeproj -scheme RepoMan -configuration Release -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" && $2 == "=" && !found { print $3; found=1 }')"
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Expected version X.Y.Z; found %s\n' "$version" >&2; exit 1; }

if [[ -z "$output_dir" ]]; then
  mkdir -p dist
  output_dir="$(mktemp -d "$repo_root/dist/build-release.XXXXXX")"
else
  if [[ -d "$output_dir" && -n "$(find "$output_dir" -mindepth 1 -print -quit)" ]]; then
    printf 'Output directory must be empty: %s\n' "$output_dir" >&2
    exit 1
  fi
  mkdir -p "$output_dir"
  output_dir="$(cd "$output_dir" && pwd)"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/repoman-build-release.XXXXXX")"
mount_dir="$work_dir/mount"
mounted=false
cleanup() {
  if [[ "$mounted" == true ]]; then hdiutil detach -quiet "$mount_dir" || true; fi
  rm -rf -- "$work_dir"
}
trap cleanup EXIT

printf 'Testing RepoMan...\n'
swift test

printf 'Building RepoMan %s for arm64...\n' "$version"
xcodebuild \
  -project RepoMan.xcodeproj \
  -scheme RepoMan \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$work_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  MARKETING_VERSION="$version" \
  build

app_path="$work_dir/DerivedData/Build/Products/Release/RepoMan.app"
info_plist="$app_path/Contents/Info.plist"
binary_path="$app_path/Contents/MacOS/RepoMan"
[[ -f "$binary_path" ]] || { printf 'Release app was not built.\n' >&2; exit 1; }
[[ "$(plutil -extract CFBundleIdentifier raw "$info_plist")" == com.tsilva.RepoMan ]] || exit 1
[[ "$(plutil -extract CFBundleShortVersionString raw "$info_plist")" == "$version" ]] || exit 1
[[ "$(plutil -extract LSMinimumSystemVersion raw "$info_plist")" == 27.0 ]] || exit 1
[[ "$(lipo -archs "$binary_path")" == arm64 ]] || exit 1
[[ -f "$app_path/Contents/Resources/AppIcon.icns" ]] || exit 1

codesign --force --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
signature_details="$(codesign -dv "$app_path" 2>&1)"
[[ "$signature_details" == *'Signature=adhoc'* ]] || exit 1

filename="RepoMan-v${version}-macOS-arm64-adhoc.dmg"
dmg_path="$output_dir/$filename"
bash Tools/package-dmg.sh "$app_path" "$dmg_path"

mkdir "$mount_dir"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mount_dir" "$dmg_path"
mounted=true
packaged_app="$mount_dir/RepoMan.app"
[[ -d "$packaged_app" && -L "$mount_dir/Applications" ]] || exit 1
[[ "$(readlink "$mount_dir/Applications")" == /Applications ]] || exit 1
[[ "$(plutil -extract CFBundleShortVersionString raw "$packaged_app/Contents/Info.plist")" == "$version" ]] || exit 1
[[ "$(lipo -archs "$packaged_app/Contents/MacOS/RepoMan")" == arm64 ]] || exit 1
codesign --verify --deep --strict --verbose=2 "$packaged_app"
hdiutil detach -quiet "$mount_dir"
mounted=false

(cd "$output_dir" && shasum -a 256 "$filename" > "$filename.sha256" && shasum -a 256 -c "$filename.sha256")

printf 'Version: %s\nDMG: %s\nSHA256: %s.sha256\n' "$version" "$dmg_path" "$dmg_path"
