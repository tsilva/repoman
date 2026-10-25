#!/bin/bash
set -euo pipefail

# Xcode embeds the same sources used by the Swift package, without package resolution.
output="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/repoman"
mkdir -p "$(dirname "$output")" "$DERIVED_FILE_DIR/repoman-cli"
optimization=-Onone
if [[ "$CONFIGURATION" == Release ]]; then optimization=-O; fi
binaries=()
for architecture in $ARCHS; do
    binary="$DERIVED_FILE_DIR/repoman-cli/repoman-$architecture"
    xcrun swiftc -parse-as-library "$optimization" -module-name RepoManCLI \
        -target "${architecture}-apple-macos${MACOSX_DEPLOYMENT_TARGET}" -sdk "$SDKROOT" \
        "$SRCROOT"/RepoManCore/*.swift "$SRCROOT"/RepoManCLI/*.swift -o "$binary"
    binaries+=("$binary")
done
if [[ ${#binaries[@]} == 1 ]]; then
    cp "${binaries[0]}" "$output"
else
    xcrun lipo -create "${binaries[@]}" -output "$output"
fi
codesign --force --sign - "$output"
