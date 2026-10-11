#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-external-media.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
 'Open Wallpaper Engine/Services/SceneParsers/SceneModels.swift' \
 tests/ExternalMediaTests.swift -o "$build_dir/tests"
"$build_dir/tests"
