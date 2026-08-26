#!/bin/bash
# HealthBoost launcher script
CONFIG="/var/jb/Library/HealthBoost/config.plist"
BINARY="/var/jb/usr/bin/HealthBoost"

if [ -f "$CONFIG" ] && [ -f "$BINARY" ]; then
    # Read enabled status
    ENABLED=$(plutil -convert xml1 -o - "$CONFIG" 2>/dev/null | grep -A1 '<key>enabled</key>' | grep '<true/>' || echo "")
    if [ -n "$ENABLED" ]; then
        # Trigger the daemon
        launchctl kickstart -k system/com.sykes.healthboost 2>/dev/null || true
        # Show alert
        osascript -e 'display dialog "HealthBoost has been triggered!" with title "HealthBoost" buttons {"OK"} default button "OK"' 2>/dev/null
    else
        osascript -e 'display dialog "HealthBoost is disabled. Enable it in Settings." with title "HealthBoost" buttons {"OK"} default button "OK"' 2>/dev/null
    fi
fi
