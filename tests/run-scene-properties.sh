#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="${1:?Usage: tests/run-scene-properties.sh /path/to/3799672625}"
build_dir=$(mktemp -d /tmp/we-properties-tests.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
# Compile the production editor without the unrelated library sidebar dependencies.
python3 - "$build_dir/Editor.swift" <<'PY'
import sys
from pathlib import Path
source = Path('Open Wallpaper Engine/ContentView/Components/WallpaperPreview.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\n' + source[source.index('struct ScenePropertiesEditor: View'):])
PY
swiftc -module-cache-path "$build_dir/cache" \
  'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
  'Open Wallpaper Engine/Services/WEProject.swift' \
  "$build_dir/Editor.swift" tests/ScenePropertiesUITests.swift -o "$build_dir/tests"
"$build_dir/tests" "$fixture"
