#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-steam-isolation.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/cache" -parse-as-library \
  'Open Wallpaper Engine/Services/SteamCmdService.swift' \
  'Open Wallpaper Engine/Services/SteamDownloadProcess.swift' \
  tests/SteamServiceIsolationTests.swift -o "$build_dir/tests"
"$build_dir/tests"
