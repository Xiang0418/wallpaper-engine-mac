#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-compat-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/WallpaperPlaybackSession.swift' \
 'Open Wallpaper Engine/Services/SceneParsers/'*.swift \
 'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
 'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
 tests/SceneCompatibilityTests.swift -o "$build_dir/tests"
"$build_dir/tests" 2>&1 | tee "$build_dir/output.log"
if rg -q 'SKShader failed to compile|MTLLibraryErrorDomain|error:' "$build_dir/output.log"; then exit 1; fi
