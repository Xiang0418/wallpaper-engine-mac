#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-external-media.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
 'Open Wallpaper Engine/Services/SceneParsers/SceneModels.swift' \
 tests/ExternalMediaTests.swift -o "$build_dir/tests"
if [[ "${1:-}" == "--live-now-playing" ]]; then
    app="$build_dir/MediaBridgeTest.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.wallpaper.media</string>
<key>CFBundleExecutable</key><string>MediaBridgeTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    cp "$build_dir/tests" "$app/Contents/MacOS/MediaBridgeTest"
    bash scripts/build-media-bridge.sh "$app/Contents/Resources/MediaRemoteBridge"
    "$app/Contents/MacOS/MediaBridgeTest" --live-now-playing
else
    "$build_dir/tests"
fi
