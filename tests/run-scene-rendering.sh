#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="${1:?Usage: tests/run-scene-playback.sh /path/to/3799672625}"
build_dir="$(mktemp -d /tmp/we-render-tests.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
swiftc -module-cache-path "$build_dir/cache" \
  'Open Wallpaper Engine/Services/SceneParsers/PKGParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/TEXParser.swift' \
  'Open Wallpaper Engine/Services/SceneParsers/SceneModels.swift' \
  'Open Wallpaper Engine/Services/SceneWallpaperViewModel.swift' \
  tests/SceneRenderingTests.swift -o "$build_dir/smoke"
"$build_dir/smoke" "$fixture" 2>&1 | tee "$build_dir/render.log"
if grep -Eq 'SKShader failed to compile|MTLLibraryErrorDomain|error:' "$build_dir/render.log"; then
  echo "GPU shader compilation failed" >&2
  exit 1
fi
