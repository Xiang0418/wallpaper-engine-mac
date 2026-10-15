#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

build_dir=$(mktemp -d /tmp/we-tex-video-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
cp tests/TEXVideoContainerTests.swift "$build_dir/main.swift"
swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/SceneParsers/PKGParser.swift' \
 'Open Wallpaper Engine/Services/SceneParsers/TEXParser.swift' \
 "$build_dir/main.swift" -o "$build_dir/tests"
"$build_dir/tests" "$@"
