#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="${1:?Usage: tests/run-scene-playback.sh /path/to/3799672625}"
build_dir="$(mktemp -d /tmp/we-scene-tests.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
swiftc -module-cache-path "$build_dir/cache" \
  'Open Wallpaper Engine/Services/WallpaperPlaybackSession.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/PKGParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/TEXParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/SceneModels.swift' \
  'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
  'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
  tests/ScenePlaybackSmoke.swift -o "$build_dir/smoke"
"$build_dir/smoke" "$fixture"
