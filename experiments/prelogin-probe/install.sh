#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run this script with sudo.'; exit 1; }
cd "$(dirname "$0")/../.."
target=/Library/PrivilegedHelperTools/WallpaperLoginProbe.app
plist=/Library/LaunchAgents/org.openwallpaperengine.prelogin-probe.plist
[[ ! -e "$target" && ! -e "$plist" ]] || { echo 'Probe already exists; uninstall first.'; exit 1; }
codesign --verify --strict build/prelogin-probe/WallpaperLoginProbe.app
mkdir -p /Library/PrivilegedHelperTools /Library/LaunchAgents
ditto build/prelogin-probe/WallpaperLoginProbe.app "$target"
chown -R root:wheel "$target"
chmod -R go-w "$target"
expires=$(( $(date +%s) + 3600 ))
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>org.openwallpaperengine.prelogin-probe</string>
<key>ProgramArguments</key><array>
<string>$target/Contents/MacOS/WallpaperLoginProbe</string>
<string>--expires</string><string>$expires</string>
</array>
<key>LimitLoadToSessionType</key><string>LoginWindow</string>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><false/>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
chown root:wheel "$plist"
chmod 644 "$plist"
plutil -lint "$plist"
echo 'Installed. Log out within one hour. Each run exits after 90 seconds. No logout was triggered.'
