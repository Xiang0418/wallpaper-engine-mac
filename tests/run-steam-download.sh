#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-download-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
swiftc -module-cache-path "$build_dir/cache" 'Open Wallpaper Engine/Services/SteamDownloadProcess.swift' tests/SteamDownloadTests.swift -o "$build_dir/tests"
"$build_dir/tests"
