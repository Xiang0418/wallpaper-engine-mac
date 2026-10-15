#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="${1:?Usage: tests/run-puppet.sh /path/to/3282304687}"
build_dir=$(mktemp -d /tmp/we-puppet-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
swiftc -O -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/WallpaperPlaybackSession.swift' \
 'Open Wallpaper Engine/Services/SceneParsers/'*.swift \
 'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
 'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
 tests/PuppetTests.swift -o "$build_dir/tests"
"$build_dir/tests" "$fixture"
