#!/usr/bin/env bash
# One-time setup of a Meta Quest headset for the kiosk loader.
#
# Needs developer mode on the headset and adb access (USB, or wireless adb).
# Usage: scripts/provision-quest.sh <loader.apk> <target package> [adb serial]
#   e.g. scripts/provision-quest.sh app-debug.apk com.example.headjackapp
#
# Install the target first, with `adb install -g <target.apk>` so its runtime permissions are
# granted up front: the watchdog relaunches the target over a permission prompt that stays open
# longer than the grace period, which may close the prompt (manual check 8 in e2e/README.md).
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

# pm lists every package containing $TARGET. Not grep -q: stopping at the first match can kill
# adb with SIGPIPE, which pipefail would report as "not installed".
if ! "${ADB[@]}" shell pm list packages "$TARGET" | grep -Fx "package:$TARGET" >/dev/null; then
    echo "Target app $TARGET is not installed on the headset. Install it first." >&2
    exit 1
fi

echo "Granting background launch and usage access..."
"${ADB[@]}" shell appops set "$LOADER" SYSTEM_ALERT_WINDOW allow
"${ADB[@]}" shell appops set "$LOADER" GET_USAGE_STATS allow
# Android saves app-op changes ~10 s later: a reboot or power cut before that would lose them.
if ! "${ADB[@]}" shell appops write-settings >/dev/null; then
    echo "Warning: could not save the grants right away. Restart the headset only from its power menu (a clean shutdown saves them), not with adb reboot or a forced power-off." >&2
fi
"${ADB[@]}" shell dumpsys deviceidle whitelist "+$LOADER" >/dev/null

# Android's "<app> has stopped" and "isn't responding" dialogs wait for someone to tap them, which
# nobody can without a controller or hands. With them hidden, a crashed app just closes and the
# watchdog brings it back.
echo "Hiding crash and not-responding dialogs..."
"${ADB[@]}" shell settings put global hide_error_dialogs 1

# Without a PIN or password, Android still shows a lock screen after a restart that waits for a
# tap. Turn it off, so the headset boots straight into Horizon OS and the target. This only works
# while no PIN, pattern or password is set; with one, the headset keeps asking for it.
echo "Turning the lock screen off..."
if ! "${ADB[@]}" shell locksettings set-disabled true; then
    echo "Warning: could not turn the lock screen off. If the headset has a PIN, pattern or password, remove it; nobody can enter it without a controller." >&2
fi

echo "Setting target to $TARGET..."
"${ADB[@]}" shell am broadcast \
    -n "$LOADER/.receiver.AdminCommandReceiver" \
    -a "$LOADER.action.SET_TARGET" --es package "$TARGET"

# Opening the loader once takes it out of the "stopped" state, so BOOT_COMPLETED
# reaches it from now on, and starts the watchdog without waiting for a reboot.
echo "Starting the loader..."
"${ADB[@]}" shell am start -n "$LOADER/.ui.MainActivity"

# Android saves the battery optimisation exemption ~5 s after it is set, and it can't be forced.
echo "Waiting for the headset to save the settings..."
sleep 6

echo "Done. $TARGET will start after boot and be relaunched if it exits or crashes."
