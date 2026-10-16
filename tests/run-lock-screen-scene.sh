#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d /tmp/we-lock-scene.XXXXXX)
trap 'rm -rf "$TASK_TMP"' EXIT
swiftc -module-cache-path "$TASK_TMP/cache" \
 'Open Wallpaper Engine/Services/WallpaperPlaybackSession.swift' \
 'Open Wallpaper Engine/Services/SceneParsers/'*.swift \
 'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
 'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
 'Open Wallpaper Engine/Services/LockScreen/LockScreenStore.swift' \
 'Open Wallpaper Engine/Services/LockScreen/LockScreenVideoEncoder.swift' \
 'Open Wallpaper Engine/Services/LockScreen/LockScreenSceneRecorder.swift' \
 tests/LockScreenSceneRecorderTests.swift -o "$TASK_TMP/test"
"$TASK_TMP/test" "$1" "$2"
