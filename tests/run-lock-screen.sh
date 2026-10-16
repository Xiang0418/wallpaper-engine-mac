#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
swiftc -module-cache-path "$TASK_TMP/modules" 'Open Wallpaper Engine/Services/LockScreen/LockScreenStore.swift' tests/LockScreenStoreTests.swift -o "$TASK_TMP/store-tests"
"$TASK_TMP/store-tests"
swiftc -module-cache-path "$TASK_TMP/modules" 'Open Wallpaper Engine/Services/LockScreen/LockScreenStore.swift' 'Open Wallpaper Engine/Services/LockScreen/LockScreenSyncService.swift' tests/LockScreenSyncTests.swift -o "$TASK_TMP/sync-tests"
"$TASK_TMP/sync-tests"
if [[ $# -gt 0 ]]; then
    swiftc -module-cache-path "$TASK_TMP/modules" 'Open Wallpaper Engine/Services/LockScreen/LockScreenStore.swift' 'Open Wallpaper Engine/Services/LockScreen/LockScreenVideoEncoder.swift' tests/LockScreenEncoderTests.swift -o "$TASK_TMP/encoder-tests"
    "$TASK_TMP/encoder-tests" "$1" "$TASK_TMP/output.mov"
fi
