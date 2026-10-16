#!/bin/bash
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run this script with sudo.'; exit 1; }
# Run after logging back in: the LoginWindow session has already ended.
rm -f /Library/LaunchAgents/org.openwallpaperengine.prelogin-probe.plist
rm -rf /Library/PrivilegedHelperTools/WallpaperLoginProbe.app
echo 'Removed login probe.'
