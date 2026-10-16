#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d /tmp/we-preset-resolver.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT
swiftc -module-cache-path "$build_dir/cache" 'Open Wallpaper Engine/Services/WEProject.swift' tests/PresetResolverTests.swift -o "$build_dir/tests"
"$build_dir/tests"
