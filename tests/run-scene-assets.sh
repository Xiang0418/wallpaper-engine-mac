#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-assets-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/SceneParsers/PKGParser.swift' \
 'Open Wallpaper Engine/Services/SceneParsers/SceneAssetResolver.swift' \
 tests/SceneAssetTests.swift -o "$build_dir/tests"
"$build_dir/tests"
