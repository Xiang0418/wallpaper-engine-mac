#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-shared-render-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/WallpaperPlaybackSession.swift' \
 'Open Wallpaper Engine/Services/SceneParsers/'*.swift \
 'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
 'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
 tests/SceneSharedAssetRenderingTests.swift -o "$build_dir/tests"
"$build_dir/tests"
