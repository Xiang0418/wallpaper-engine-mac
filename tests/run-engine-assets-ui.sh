#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-engine-assets-ui.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/SceneParsers/PKGParser.swift' \
 'Open Wallpaper Engine/Services/SceneParsers/SceneAssetResolver.swift' \
 'Open Wallpaper Engine/Services/SteamDownloadProcess.swift' \
 'Open Wallpaper Engine/Services/SteamCmdService.swift' \
 'Open Wallpaper Engine/Services/EngineAssetsService.swift' \
 'Open Wallpaper Engine/SettingsView/EngineAssetsSettingsSection.swift' \
 tests/EngineAssetsSettingsUITests.swift -o "$build_dir/tests"
"$build_dir/tests"
