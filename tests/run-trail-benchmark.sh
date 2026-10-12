#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
output_dir="${1:-build/trail-benchmark}"
mkdir -p "$output_dir"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/we-trail-benchmark.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc -O -module-cache-path "$build_dir/cache" \
  'Open Wallpaper Engine/Services/SceneRuntime/SceneRopeTrail.swift' \
  tests/TrailBenchmark.swift -o "$build_dir/benchmark"
"$build_dir/benchmark" "$output_dir/current" | tee "$output_dir/current.txt"
