#!/usr/bin/env bash
# One-time setup of a Meta Quest headset for the kiosk loader.
#
# Needs developer mode on the headset and adb access (USB, or wireless adb).
# Usage: scripts/provision-quest.sh <loader.apk> <target package> [adb serial]
#   e.g. scripts/provision-quest.sh app-debug.apk com.example.headjackapp
set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <loader.apk> <target package> [adb serial]" >&2
    exit 1
fi

APK="$1"
TARGET="$2"
LOADER="com.osamaalek.kiosklauncher"
ADB=(adb)
[[ $# -ge 3 ]] && ADB+=(-s "$3")

echo "Installing loader..."
"${ADB[@]}" install -r -g "$APK"

if ! "${ADB[@]}" shell pm list packages "$TARGET" | grep -qx "package:$TARGET"; then
    echo "Target app $TARGET is not installed on the headset. Install it first." >&2
    exit 1
fi

echo "Granting background launch and usage access..."
"${ADB[@]}" shell appops set "$LOADER" SYSTEM_ALERT_WINDOW allow
"${ADB[@]}" shell appops set "$LOADER" GET_USAGE_STATS allow
"${ADB[@]}" shell dumpsys deviceidle whitelist "+$LOADER" >/dev/null

echo "Setting target to $TARGET..."
"${ADB[@]}" shell am broadcast \
    -n "$LOADER/.receiver.AdminCommandReceiver" \
    -a "$LOADER.action.SET_TARGET" --es package "$TARGET"

# Opening the loader once takes it out of the "stopped" state, so BOOT_COMPLETED
# reaches it from now on, and starts the watchdog without waiting for a reboot.
echo "Starting the loader..."
"${ADB[@]}" shell am start -n "$LOADER/.ui.MainActivity"

echo "Done. $TARGET will start after boot and be relaunched if it exits or crashes."
