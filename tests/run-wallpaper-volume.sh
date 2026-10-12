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
  'Open Wallpaper Engine/Services/SceneParsers/TEXParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/SceneModels.swift' \
  'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
  'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
  'Open Wallpaper Engine/Services/WEProject.swift' \
  'Open Wallpaper Engine/Services/WallpaperViewModel.swift' \
  'Open Wallpaper Engine/Services/VideoWallpaperViewModel.swift' \
  'Open Wallpaper Engine/GlobalComponents/WallpaperVolumeControl.swift' \
  tests/WallpaperVolumeTests.swift -o "$build_dir/volume-tests"
"$build_dir/volume-tests" "$@"
