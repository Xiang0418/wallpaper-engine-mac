#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out="$PWD/build/prelogin-probe/WallpaperLoginProbe.app"
mkdir -p "$out/Contents/Resources" "$out/Contents/MacOS" "$PWD/build/prelogin-probe/module-cache"
xcrun swiftc experiments/prelogin-probe/main.swift -o "$out/Contents/MacOS/WallpaperLoginProbe" \
  -module-cache-path "$PWD/build/prelogin-probe/module-cache" -framework AppKit -framework SystemConfiguration
xcrun swiftc experiments/prelogin-probe/generate-video.swift -o "$PWD/build/prelogin-probe/generate-video" \
  -module-cache-path "$PWD/build/prelogin-probe/module-cache" -framework AVFoundation
"$PWD/build/prelogin-probe/generate-video" "$out/Contents/Resources/test-loop.mov"
cat > "$out/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.openwallpaperengine.prelogin-probe</string>
<key>CFBundleExecutable</key><string>WallpaperLoginProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$out"
codesign --verify --strict "$out"
printf 'Built: %s\n' "$out"
