#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/we-media-settings.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
python3 - "$build_dir/Section.swift" <<'PY'
import sys
from pathlib import Path
source = Path('Open Wallpaper Engine/SettingsView/GeneralPage.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\n' + source[source.index('struct ExternalMediaSettingsSection: View'):])
PY
xcrun swiftc -module-cache-path "$build_dir/cache" \
 'Open Wallpaper Engine/Services/SceneParsers/MDLParser.swift' \
 'Open Wallpaper Engine/Services/SceneRuntime/'*.swift \
 "$build_dir/Section.swift" tests/MediaSettingsUITests.swift -o "$build_dir/tests"
"$build_dir/tests"
