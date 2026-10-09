#!/usr/bin/env bash
# Kiosk Loader installer for Meta Quest headsets.
#
# Installs the loader on a headset connected over USB, makes it start the chosen app on boot and
# bring it back whenever it closes or crashes, and sets the headset up for use without
# controllers. Run it once per headset, from the folder it came in:
#
#   ./install.sh                                  # asks which app to keep running
#   ./install.sh --target com.example.app         # or name it
#   ./install.sh --target com.example.app --grace 3 --serial 2G97C5ZJ0H00YS
#
#   --target PKG     the app to keep running (must already be installed on the headset)
#   --grace SECONDS  how long the app may be gone before it is started again, 0 to 60
#                    (default: the loader's own, 10)
#   --serial SERIAL  which headset, when more than one is connected (see: adb devices)
#
# Needs adb (Android platform tools) and, on the headset, developer mode with USB debugging
# allowed for this computer. Running it again on a headset updates the loader and keeps it set up.
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
APK=$DIR/kiosk-loader.apk
PROVISION=$DIR/provision-quest.sh
LOADER=com.osamaalek.kiosklauncher
RECEIVER=$LOADER/.receiver.AdminCommandReceiver
ACTION=$LOADER.action

TARGET=""
GRACE=""
SERIAL=""

die() {
    printf '\nError: %s\n' "$*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --target) TARGET=${2:-}; shift 2 ;;
        --grace) GRACE=${2:-}; shift 2 ;;
        --serial) SERIAL=${2:-}; shift 2 ;;
        -h | --help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1 (see ./install.sh --help)" ;;
    esac
done

[[ -f $APK ]] || die "kiosk-loader.apk is missing: keep install.sh in the folder it came in"
[[ -f $PROVISION ]] || die "provision-quest.sh is missing: keep install.sh in the folder it came in"
if [[ -n $GRACE ]] && ! [[ $GRACE =~ ^[0-9]+$ && $GRACE -le 60 ]]; then
    die "--grace takes 0 to 60 seconds, got '$GRACE'"
fi

# --- adb ---------------------------------------------------------------------------------------

ADB_BIN=""
for candidate in "$(command -v adb 2>/dev/null || true)" \
    "${ANDROID_HOME:-}/platform-tools/adb" "${ANDROID_SDK_ROOT:-}/platform-tools/adb" \
    "$HOME/Library/Android/sdk/platform-tools/adb" "$HOME/Android/Sdk/platform-tools/adb" \
    "$DIR/platform-tools/adb"; do
    if [[ -n $candidate && -x $candidate ]]; then
        ADB_BIN=$candidate
        break
    fi
done
[[ -n $ADB_BIN ]] || die "adb not found. Install Android platform tools (macOS: brew install --cask android-platform-tools), or put its platform-tools folder next to install.sh"
# provision-quest.sh runs plain `adb`: make it this one
export PATH="$(dirname "$ADB_BIN"):$PATH"

# --- headset -----------------------------------------------------------------------------------

echo "Looking for the headset..."
devices=$(adb devices | awk 'NR > 1 && NF >= 2 { print $1, $2 }')
if [[ -z $SERIAL ]]; then
    count=$(printf '%s\n' "$devices" | grep -c . || true)
    if ((count == 0)); then
        die "no headset found. Connect it with a USB cable, turn on developer mode in the Meta Horizon phone app, put the headset on and allow USB debugging"
    elif ((count > 1)); then
        echo "More than one device is connected:"
        printf '  %s\n' "$devices"
        read -r -p "Serial of the headset to set up: " SERIAL
    else
        SERIAL=$(printf '%s\n' "$devices" | awk '{ print $1 }')
    fi
fi
state=$(printf '%s\n' "$devices" | awk -v s="$SERIAL" '$1 == s { print $2 }')
case $state in
    device) ;;
    unauthorized) die "the headset hasn't allowed this computer yet. Put it on, tick 'Always allow from this computer' in the USB debugging prompt (or find it under notifications) and allow, then run this again" ;;
    "") die "no device with serial $SERIAL (see: adb devices)" ;;
    *) die "the headset is '$state'. Reconnect the cable and run this again" ;;
esac
ADB=(adb -s "$SERIAL")
model=$("${ADB[@]}" shell getprop ro.product.model | tr -d '\r')
os=$("${ADB[@]}" shell getprop ro.build.display.id | tr -d '\r')
echo "Headset: $model ($os), serial $SERIAL"

# --- app to keep running -----------------------------------------------------------------------

if [[ -z $TARGET ]]; then
    apps=$("${ADB[@]}" shell pm list packages -3 | tr -d '\r' | sed 's/^package://' |
        grep -v -x -e "$LOADER" -e "$LOADER.testapp" -e "$LOADER.testapp.vr" | sort || true)
    [[ -n $apps ]] || die "no apps installed on the headset besides the loader. Install the app first"
    echo
    echo "Apps installed on the headset:"
    printf '%s\n' "$apps" | nl -w3 -s'. '
    read -r -p "Number of the app to keep running: " choice
    [[ $choice =~ ^[0-9]+$ ]] || die "not a number: '$choice'"
    TARGET=$(printf '%s\n' "$apps" | sed -n "${choice}p")
    [[ -n $TARGET ]] || die "no app number $choice"
fi
"${ADB[@]}" shell pm list packages "$TARGET" | tr -d '\r' | grep -Fx "package:$TARGET" >/dev/null ||
    die "$TARGET is not installed on the headset. Install it first (adb install -g <app>.apk grants its permissions up front)"
echo "App to keep running: $TARGET"

# --- install and set up ------------------------------------------------------------------------

echo
# An older loader signed with another key can't be updated in place
if "${ADB[@]}" shell pm list packages "$LOADER" | tr -d '\r' | grep -Fx "package:$LOADER" >/dev/null &&
    ! "${ADB[@]}" install -r -g "$APK" >/dev/null 2>&1; then
    echo "The loader on the headset was signed with another key; replacing it (its settings are reset)."
    "${ADB[@]}" uninstall "$LOADER" >/dev/null
fi
bash "$PROVISION" "$APK" "$TARGET" "$SERIAL"

if [[ -n $GRACE ]]; then
    echo "Setting the relaunch delay to $GRACE s..."
    out=$("${ADB[@]}" shell am broadcast -n "$RECEIVER" -a "$ACTION.SET_GRACE" --ei seconds "$GRACE" | tr -d '\r')
    [[ $out == *'data="OK"'* ]] || echo "Warning: could not set the relaunch delay ($out); set it on the loader's screen" >&2
fi

# --- check -------------------------------------------------------------------------------------

echo
echo "Checking..."
ok=yes
check() {
    if [[ $2 == "$3" ]]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s (got: %s)\n' "$1" "${2:-nothing}"
        ok=no
    fi
}
appops=$("${ADB[@]}" shell appops get "$LOADER" | tr -d '\r')
check "start apps from the background" "$(printf '%s\n' "$appops" | grep -o 'SYSTEM_ALERT_WINDOW: [a-z]*' | head -1)" "SYSTEM_ALERT_WINDOW: allow"
check "see which app is in front" "$(printf '%s\n' "$appops" | grep -o 'GET_USAGE_STATS: [a-z]*' | head -1)" "GET_USAGE_STATS: allow"
# Captured first, then matched: grep -q stopping early could fail the pipeline (pipefail)
idle=$("${ADB[@]}" shell dumpsys deviceidle whitelist | tr -d '\r')
check "not stopped by battery saving" "$([[ $idle == *",$LOADER,"* ]] && echo yes)" "yes"
check "no crash dialogs" "$("${ADB[@]}" shell settings get global hide_error_dialogs | tr -d '\r')" "1"
check "no lock screen" "$("${ADB[@]}" shell locksettings get-disabled 2>/dev/null | tr -d '\r')" "true"
services=$("${ADB[@]}" shell dumpsys activity services "$LOADER" | tr -d '\r')
check "watchdog running" "$([[ $services == *WatchdogService* ]] && echo yes)" "yes"

cat <<EOF

On the headset, once:
  - Settings: turn the boundary (Guardian) off, so the app isn't held up after the headset wakes
  - Settings: hand tracking off and controllers away, if users get it that way
  - The first time it asks, tick "Always allow from this computer" for USB debugging

Test it: restart the headset (hold the power button until it turns off, then turn it on).
$TARGET should start by itself, and come back within a few seconds whenever it closes.
EOF
if [[ $ok == no ]]; then
    echo
    echo "Some checks failed (above). Run ./install.sh again; if they still fail, keep this output."
    exit 1
fi
