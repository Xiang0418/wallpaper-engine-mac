#!/bin/bash
set -euo pipefail
# Invoked by Xcode, or with an explicit output directory for the integration test.
source_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
output="${1:-${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/MediaRemoteBridge}"
vendor="$source_root/Vendor/MediaRemoteAdapter"
# Xcode grants literal paths for declared outputs, not recursive directory
# access. Compile/sign in its writable temporary directory, then install only
# the declared files (codesign may otherwise create undeclared temporary files).
staging=$(mktemp -d "${TEMP_DIR:-${TMPDIR:-/tmp}}/we-media-bridge.XXXXXX")
trap 'rm -rf "$staging"' EXIT
framework="$staging/MediaRemoteAdapter.framework"
mkdir -p "$framework"
arch_args=()
for arch in ${ARCHS:-arm64 x86_64}; do arch_args+=(-arch "$arch"); done
xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -mmacosx-version-min=13.0 \
  "${arch_args[@]}" -isysroot "${SDKROOT:-$(xcrun --show-sdk-path)}" \
  -I "$vendor/include" -I "$vendor/src" \
  "$vendor"/src/adapter/*.m "$vendor"/src/private/*.m "$vendor"/src/utility/*.m \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name '@rpath/MediaRemoteAdapter.framework/MediaRemoteAdapter' \
  -o "$framework/MediaRemoteAdapter"
cat > "$framework/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>com.vandenbe.MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$framework"
destination="$output/MediaRemoteAdapter.framework"
mkdir -p "$destination/_CodeSignature"
cp -X "$framework/MediaRemoteAdapter" "$destination/MediaRemoteAdapter"
cp -X "$framework/Info.plist" "$destination/Info.plist"
cp -X "$framework/_CodeSignature/CodeResources" "$destination/_CodeSignature/CodeResources"
cp -X "$vendor/bin/mediaremote-adapter.pl" "$output/mediaremote-adapter.pl"
cp -X "$vendor/LICENSE" "$output/LICENSE"
