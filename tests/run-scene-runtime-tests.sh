#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/we-runtime-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -module-cache-path "$build_dir/cache" \
  'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
  Tests/SceneRuntimeTests.swift -o "$build_dir/tests"
"$build_dir/tests" "$@"
