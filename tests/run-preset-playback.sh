#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/we-volume-tests.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
cp 'Open Wallpaper Engine/Resources/WallpaperNotFound.mp4' "$build_dir/"
swiftc -module-cache-path "$build_dir/cache" \
  'Open Wallpaper Engine/Services/WallpaperPlaybackSession.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/SceneAssetResolver.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/PKGParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/MDLParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/TEXParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/SceneModels.swift' \
  'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
  'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
  'Open Wallpaper Engine/Services/WEProject.swift' \
  'Open Wallpaper Engine/Services/WallpaperViewModel.swift' \
  'Open Wallpaper Engine/Services/VideoWallpaperViewModel.swift' \
  'Open Wallpaper Engine/GlobalComponents/WallpaperVolumeControl.swift' \
  tests/PresetPlaybackTests.swift -o "$build_dir/volume-tests"
if [[ "${3:-}" == "--live-media" ]]; then
    app="$build_dir/PresetMediaTest.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.wallpaper.preset-media</string>
<key>CFBundleExecutable</key><string>PresetMediaTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
    cp "$build_dir/volume-tests" "$app/Contents/MacOS/PresetMediaTest"
    cp 'Open Wallpaper Engine/Resources/WallpaperNotFound.mp4' "$app/Contents/Resources/"
    ditto '/Applications/Open Wallpaper Engine.app/Contents/Resources/MediaRemoteBridge' "$app/Contents/Resources/MediaRemoteBridge"
    "$app/Contents/MacOS/PresetMediaTest" "$@"
else
    "$build_dir/volume-tests" "$@"
fi
