#!/usr/bin/env bash
# Guided test run on a real Quest (e2e/README.md, "Manual checks on a Quest"). It runs the
# automated suite on the headset, sets the headset up again for its real target, then walks
# through the checks only a headset can answer: adb does and measures what it can, and you are
# asked for the rest. Everything ends up in one zip to send back. The headset is left
# provisioned for the real target.
#
# Usage: e2e/quest-check.sh --target PACKAGE [options]
#   --target PKG           the app the headset keeps running (e.g. your Headjack app); must be
#                          installed on the headset
#   --loader-apk APK       debug loader for the suite
#                          (default: app/build/outputs/apk/debug/app-debug.apk)
#   --provision-apk APK    loader to leave on the headset (default: the --loader-apk one; use
#                          app-release.apk once release signing is set up)
#   --target-apk APK       launcher test app for the suite (default: testapp build output)
#   --vr-target-apk APK    VR test app for the suite (default: testapp build output)
#   --serial SERIAL        adb serial, if more than one device is attached
#   --skip-suite           only the headset checks, not the automated suite
#   --out DIR              where everything goes (default: e2e/results/quest-<date>-<time>)
# Relative paths are taken from the current directory.
set -euo pipefail

E2E_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$E2E_DIR/.." && pwd)
# shellcheck source=e2e/lib.sh
source "$E2E_DIR/lib.sh"

TARGET=""
LOADER_APK=$REPO_ROOT/app/build/outputs/apk/debug/app-debug.apk
PROVISION_APK=""
TEST_APK=$REPO_ROOT/testapp/build/outputs/apk/launcher/debug/testapp-launcher-debug.apk
VR_TEST_APK=$REPO_ROOT/testapp/build/outputs/apk/vr/debug/testapp-vr-debug.apk
SKIP_SUITE=no
OUT=""
PROX_OVERRIDE=no   # whether we told the headset it is worn (com.oculus.vrpowermanager.prox_close)
CAPTURE_PID=""     # background logcat loop
PACKED=no
SUMMARY_READY=no

die() {
    echo "Error: $*" >&2
    exit 2
}

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'
}

abs_path() {
    case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PWD/$1" ;;
    esac
}

parse_args() {
    while (($#)); do
        case $1 in
        --target | --loader-apk | --provision-apk | --target-apk | --vr-target-apk | --serial | --out)
            (($# >= 2)) || die "$1 needs a value"
            case $1 in
            --target) TARGET=$2 ;;
            --loader-apk) LOADER_APK=$(abs_path "$2") ;;
            --provision-apk) PROVISION_APK=$(abs_path "$2") ;;
            --target-apk) TEST_APK=$(abs_path "$2") ;;
            --vr-target-apk) VR_TEST_APK=$(abs_path "$2") ;;
            --serial) E2E_SERIAL=$2 ;;
            --out) OUT=$(abs_path "$2") ;;
            esac
            shift 2
            ;;
        --skip-suite) SKIP_SUITE=yes && shift ;;
        -h | --help) usage && exit 0 ;;
        *) die "unknown option $1 (see --help)" ;;
        esac
    done
    [[ -n $TARGET ]] || die "--target <package> is required: the app the headset should keep running"
    [[ -n $PROVISION_APK ]] || PROVISION_APK=$LOADER_APK
    [[ -n $OUT ]] || OUT=$REPO_ROOT/e2e/results/quest-$(date '+%Y%m%d-%H%M%S')
}

# --- Terminal ---------------------------------------------------------------------------------

say() {
    printf '%s\n' "$*"
    printf '%s\n' "$*" >>"$RUN_LOG"
}

# pause_for TEXT [TITLE]: shows what to do; returns 1 if the check is skipped (and records
# TITLE as skipped, if given)
pause_for() {
    local ans
    printf '\n%s\n' "$1"
    read -r -p "Press Enter when done, or s and Enter to skip this check: " ans || ans=s
    if [[ $ans == [sS]* ]]; then
        if [[ -n ${2:-} ]]; then record "$2" "skipped"; fi
        return 1
    fi
}

# ask QUESTION: a free answer on stdout ("" if none)
ask() {
    local ans
    read -r -p "$1 " ans || ans=""
    printf '%s\n' "$ans"
}

# ask_yn QUESTION: y, n or ? (no answer) on stdout
ask_yn() {
    local ans
    read -r -p "$1 [y/n] " ans || ans=""
    case $ans in
    [yY]*) echo y ;;
    [nN]*) echo n ;;
    *) echo "?" ;;
    esac
}

# record TITLE LINES...: one check's result in checks.md
record() {
    local title=$1 line
    shift
    {
        printf '\n## %s\n\n' "$title"
        for line in "$@"; do printf -- '- %s\n' "$line"; done
    } >>"$OUT/checks.md"
}

# --- Device -----------------------------------------------------------------------------------

find_adb() {
    local sdk found=""
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
        if [[ -n $sdk && -x $sdk/platform-tools/adb ]]; then
            found=$sdk/platform-tools/adb
            break
        fi
    done
    [[ -n $found ]] || found=$(command -v adb 2>/dev/null) || found=""
    [[ -n $found ]] || die "adb not found: install Android platform-tools or set ANDROID_HOME"
    ADB=$found
    PATH="$(dirname "$ADB"):$PATH" # provision-quest.sh runs plain `adb`
    export PATH
}

pick_device() {
    local devices count
    if [[ -n $E2E_SERIAL ]]; then
        device_online || die "$E2E_SERIAL is not attached (or not authorized: put the headset on and accept 'Allow USB debugging')"
        return
    fi
    devices=$("$ADB" devices </dev/null | tr -d '\r' | awk 'NR > 1 && $2 == "device" { print $1 }')
    count=$(printf '%s' "$devices" | grep -c . || true)
    ((count == 1)) || die "found $count usable adb devices; connect the headset (accept 'Allow USB debugging' inside it) or pass --serial"
    E2E_SERIAL=$devices
}

target_installed() {
    adb_shell pm list packages "$TARGET" 2>/dev/null | grep -Fx "package:$TARGET" >/dev/null
}

# relaunch_lines FROM: "Relaunching <target> (...)" lines in the capture after line FROM
relaunch_lines() {
    tail -n +"$(($1 + 1))" "$OUT/quest-checks.log" 2>/dev/null | grep -F "Relaunching $TARGET (" || true
}

capture_mark() {
    wc -l <"$OUT/quest-checks.log" | tr -d ' '
}

# The log the checks are judged on. adb logcat ends when the headset restarts; the loop waits
# for it to come back and starts again, and logcat first prints what was logged since boot.
start_capture() {
    adb_ logcat -c >/dev/null 2>&1 || true
    : >"$OUT/quest-checks.log"
    (
        trap 'exit 0' TERM
        while :; do
            "$ADB" -s "$E2E_SERIAL" wait-for-device </dev/null >/dev/null 2>&1 || true
            "$ADB" -s "$E2E_SERIAL" logcat -v time WatchdogService:I TargetLauncher:I \
                AdminCommandReceiver:I ActivityTaskManager:I ActivityManager:I AndroidRuntime:E '*:S' \
                </dev/null >>"$OUT/quest-checks.log" 2>/dev/null || true
            sleep 2
        done
    ) 2>/dev/null &
    CAPTURE_PID=$!
}

stop_capture() {
    if [[ -n $CAPTURE_PID ]]; then
        pkill -P "$CAPTURE_PID" 2>/dev/null || true
        kill "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
        CAPTURE_PID=""
    fi
}

prox_on() {
    [[ $PROX_OVERRIDE == yes ]] || return 0
    adb_shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
}

prox_off() {
    adb_shell am broadcast -a com.oculus.vrpowermanager.automation_disable >/dev/null 2>&1 || true
}

# controller_prompt_open: Horizon OS's "controllers required" launch check is open
controller_prompt_open() {
    adb_shell dumpsys activity activities 2>/dev/null | grep -q 'systemdialog\.launchcheck\.'
}

# hand_tracking_declared: the target asks for hand tracking, so Horizon OS may start it without
# a controller
hand_tracking_declared() {
    adb_shell dumpsys package "$TARGET" 2>/dev/null | grep -q 'com.oculus.permission.HAND_TRACKING'
}

# watch_front TIMEOUT: waits for the target to be in front; prints the seconds it took, or
# "not within TIMEOUT s (foreground: X)"
watch_front() {
    local timeout=$1 start=$SECONDS fg=""
    while ((SECONDS - start <= timeout)); do
        # Resumed on any display: on a Quest the focused display is often the home's
        if is_foreground "$TARGET" 2>/dev/null; then
            echo "in front after $((SECONDS - start)) s"
            return 0
        fi
        sleep 1
    done
    fg=$(foreground_pkg 2>/dev/null) || fg=""
    if controller_prompt_open; then
        echo "not in front within $timeout s: Horizon OS shows its 'controllers required' dialog instead"
    else
        echo "not in front within $timeout s (foreground: ${fg:-none})"
    fi
    return 1
}

# watch_leave TIMEOUT: waits for the target to leave the front; prints what came up
watch_leave() {
    local timeout=$1 start=$SECONDS fg=""
    while ((SECONDS - start <= timeout)); do
        if ! is_foreground "$TARGET" 2>/dev/null; then
            fg=$(foreground_pkg 2>/dev/null) || fg=""
            echo "left after $((SECONDS - start)) s (foreground: ${fg:-none})"
            return 0
        fi
        sleep 1
    done
    echo "still in front after $timeout s"
    return 1
}

relaunch_summary() {
    local lines count
    lines=$(relaunch_lines "$1")
    count=$(printf '%s' "$lines" | grep -c . || true)
    if ((count == 0)); then
        echo "watchdog log: no relaunch"
    else
        echo "watchdog log: $count relaunch(es), last: $(printf '%s\n' "$lines" | tail -1 | sed 's/.*Relaunching/Relaunching/')"
    fi
}

grants_line() {
    echo "grants: SYSTEM_ALERT_WINDOW=$(appops_mode "$LOADER_PKG" SYSTEM_ALERT_WINDOW), GET_USAGE_STATS=$(appops_mode "$LOADER_PKG" GET_USAGE_STATS), battery exemption=$(in_deviceidle_whitelist "$LOADER_PKG" && echo yes || echo no)"
}

# adb_state: what `adb devices` says about the headset (device, unauthorized, offline), empty if
# it isn't listed
adb_state() {
    "$ADB" devices 2>/dev/null </dev/null | awk -v s="$E2E_SERIAL" '$1 == s { print $2 }'
}

# wait_boot BOOT_ID TIMEOUT: waits for a new boot to finish; prints how long it took. Without a
# readable boot id, a boot is the device going offline and coming back. Says once (on stderr, as
# stdout is the result) what to do if the headset is back but adb is no longer authorized.
wait_boot() {
    local old=$1 timeout=$2 start=$SECONDS id went_down=no hinted=no
    while ((SECONDS - start <= timeout)); do
        if ! device_online; then
            went_down=yes
            if [[ $hinted == no && "$(adb_state)" == unauthorized ]]; then
                hinted=yes
                say "   adb sees the headset but it is not authorized. In the headset, look for 'Allow USB
   debugging' in front or under notifications (the bell), tick 'Always allow from this computer'
   and allow. No prompt: unplug and replug the cable; last resort: turn developer mode off and on
   in the Meta Horizon app. The script keeps waiting." >&2
            fi
        elif boot_ready; then
            id=$(boot_id)
            if [[ -n $id && -n $old && $id != "$old" ]] || [[ (-z $id || -z $old) && $went_down == yes ]]; then
                echo "$((SECONDS - start))"
                return 0
            fi
        fi
        sleep 2
    done
    return 1
}

# boot_launch_line: from the headset's own log, how long after boot the watchdog started and first
# launched the target, however late adb came back. Busy headsets rotate logcat, so a late
# reconnect may find nothing.
boot_launch_line() {
    local out
    out=$(adb_shell "cat /proc/uptime; date +%s; logcat -d -v epoch -s WatchdogService:I" 2>/dev/null) || out=""
    printf '%s\n' "$out" | awk -v pkg="$TARGET" '
        NR == 1 { up = $1; next }
        NR == 2 { boot = $1 - up; next }
        !w && index($0, "Watchdog started") { w = $1 }
        !t && index($0, "Relaunching " pkg " (") { t = $1 }
        END {
            if (w) printf "watchdog started %.0f s after boot; ", w - boot
            if (t) printf "first launch of the target %.0f s after boot\n", t - boot
            else print "no launch of the target found in logcat (it may have rotated out)"
        }'
}

# --- Steps ------------------------------------------------------------------------------------

device_info() {
    local p
    {
        echo "# Device"
        for p in ro.product.manufacturer ro.product.model ro.build.display.id ro.build.version.release \
            ro.build.version.sdk ro.build.fingerprint; do
            echo "$p=$(device_prop "$p")"
        done
        echo
        echo "# Target $TARGET"
        adb_shell dumpsys package "$TARGET" 2>/dev/null |
            grep -E 'versionName|targetSdk|launchMode|android.permission|com.oculus' | sed 's/^ *//' | sort -u || true
        echo
        echo "hand tracking requested: $(hand_tracking_declared && echo yes || echo no)"
        echo
        echo "# How it is launched"
        echo "LAUNCHER: $(adb_shell cmd package resolve-activity --brief -a android.intent.action.MAIN \
            -c android.intent.category.LAUNCHER "$TARGET" 2>/dev/null | tail -1)"
        echo "VR: $(adb_shell cmd package resolve-activity --brief -a android.intent.action.MAIN \
            -c com.oculus.intent.category.VR "$TARGET" 2>/dev/null | tail -1)"
    } >"$OUT/device-info.txt"
}

run_suite() {
    local f
    for f in "$LOADER_APK" "$TEST_APK" "$VR_TEST_APK"; do
        [[ -f $f ]] || die "APK not found: $f. Build them (./gradlew assembleDebug :testapp:assembleDebug) or download the app-debug and e2e-target-apks artifacts of a CI run and pass their paths; or use --skip-suite"
    done
    say ""
    say "== Part A: the automated suite on the headset (about 8 minutes). Keep it on your head,"
    say "   or the proximity sensor covered, unless you chose to keep the display on."
    say "   After the screen-off scenario wakes it, Horizon OS may report its Guardian service in front"
    say "   for a while, usually with nothing shown in the headset. Nothing to do: the suite waits."
    if bash "$E2E_DIR/run.sh" --allow-real-device --skip reboot --serial "$E2E_SERIAL" \
        --loader-apk "$LOADER_APK" --target-apk "$TEST_APK" --vr-target-apk "$VR_TEST_APK" \
        --results "$OUT/suite" </dev/null; then
        record "Automated suite" "all scenarios passed (suite/summary.md)"
    else
        record "Automated suite" "some scenarios failed or didn't run: see suite/summary.md"
        say "The suite had failures. That is useful data; carrying on with the checks."
    fi
}

provision_real_target() {
    local cmd
    say ""
    say "== Part B: removing the test setup and provisioning the headset for $TARGET"
    for cmd in "uninstall $LOADER_PKG" "uninstall $TARGET_PKG" "uninstall $VR_TARGET_PKG"; do
        # shellcheck disable=SC2086 # cmd is "uninstall <package>"
        adb_ $cmd >/dev/null 2>&1 || true
    done
    for cmd in "svc power stayon false" "locksettings set-disabled false" \
        "settings put global window_animation_scale 1" "settings put global transition_animation_scale 1" \
        "settings put global animator_duration_scale 1" \
        "settings delete global show_first_crash_dialog" "settings delete secure show_first_crash_dialog_dev_option" \
        "settings delete secure anr_show_background"; do
        adb_shell "$cmd" >/dev/null 2>&1 || true
    done
    [[ -f $PROVISION_APK ]] || die "APK not found: $PROVISION_APK"
    bash "$REPO_ROOT/scripts/provision-quest.sh" "$PROVISION_APK" "$TARGET" "$E2E_SERIAL" </dev/null ||
        die "provisioning failed; see the output above"
    record "Provisioning" "$(grants_line)"
}

check_first_start() {
    local mark result
    pause_for "== Check 1: first start. The loader's screen is open on the headset. Don't touch
   anything: press Enter here. $TARGET should start within about 45 s (the loader's screen holds
   it back for 30 s after it was opened, then the grace period)." \
        "1. First start after provisioning" || return 0
    mark=$(capture_mark)
    result=$(watch_front 75) || true
    say "   $TARGET $result"
    record "1. First start after provisioning" "$TARGET $result" "$(relaunch_summary "$mark")" \
        "you: started by itself = $(ask_yn "Did $TARGET start by itself?")"
}
check_exit() {
    local mark back
    pause_for "== Check 2: $TARGET exits. Without a controller nobody can quit it, but it can still
   close by itself; press Enter and the script stops it (am force-stop). It should come back
   after about 10 s." "2. Exit (force-stop)" || return 0
    mark=$(capture_mark)
    force_stop "$TARGET"
    back=$(watch_front 60) || true
    say "   $TARGET $back"
    record "2. Exit (force-stop)" "$TARGET $back" "$(relaunch_summary "$mark")" \
        "you: came back = $(ask_yn "Did $TARGET come back?")"
}
check_crash() {
    local mark out method back
    pause_for "== Check 3: a crash. Press Enter and the script crashes $TARGET over adb; it should
   come back after about 10 s." "3. Crash" || return 0
    mark=$(capture_mark)
    method="am crash"
    out=$(adb_shell am crash "$TARGET" 2>&1) || method="am force-stop"
    if [[ $method == "am force-stop" || $out == *Unknown* || $out == *Exception* ]]; then
        method="am force-stop"
        force_stop "$TARGET"
    fi
    sleep 1
    back=$(watch_front 60) || true
    say "   $method: $TARGET $back"
    record "3. Crash ($method)" "$TARGET $back" "$(relaunch_summary "$mark")" \
        "you: no dialog to approve = $(ask_yn "Did it come back with no 'has stopped' dialog or anything to tap?")"
}

check_power_button() {
    local mark timeline="" i w saw_off=no back
    pause_for "== Check 4: the headset's power button, the only button a user has. Press Enter,
   then press the power button once (the display turns off), wait about 15 s, and press it once
   more to wake the headset. The script follows the display for up to 90 s." \
        "4. Power button: sleep and wake" || return 0
    mark=$(capture_mark)
    for ((i = 0; i < 90; i += 3)); do
        w=$(wakefulness 2>/dev/null) || w=""
        timeline+="${i}s:${w:-?} "
        if [[ $w == Asleep || $w == Dozing ]]; then saw_off=yes; fi
        if [[ $saw_off == yes && $w == Awake ]]; then break; fi
        sleep 3
    done
    say "   display state every 3 s: $timeline"
    if [[ $saw_off == no ]]; then
        record "4. Power button: sleep and wake" "the display did not turn off: $timeline"
        return 0
    fi
    back=$(watch_front 60) || true
    say "   after wake: $TARGET $back"
    record "4. Power button: sleep and wake" "display state every 3 s: $timeline" \
        "after wake: $TARGET $back" "$(relaunch_summary "$mark")" \
        "you: as expected = $(ask_yn "Was $TARGET back within about 15 s of waking, with nothing to do?")"
}
check_headset_off() {
    local mark timeline="" i back
    prox_off
    pause_for "== Check 5: headset off. Press Enter, take the headset off and put it down for 30 s,
   then put it back on when this says so." "5. Headset off for about 30 s" || {
        prox_on
        return 0
    }
    mark=$(capture_mark)
    for ((i = 0; i < 40; i += 4)); do
        timeline+="${i}s:$(wakefulness 2>/dev/null || echo ?) "
        sleep 4
    done
    say "   display state every 4 s: $timeline"
    say "   Put the headset back on now."
    read -r -p "Press Enter once it is on your head again: " _ || true
    back=$(watch_front 30) || true
    say "   $TARGET $back"
    record "5. Headset off for about 30 s" "display state every 4 s: $timeline" "$TARGET after putting it on: $back" \
        "$(relaunch_summary "$mark")" \
        "you: as expected = $(ask_yn "Was $TARGET there (or back within about 10 s) with nothing odd while it was off?")"
    prox_on
}

check_loader_ui() {
    local mark early back
    pause_for "== Check 6: the loader's own screen, left open. Press Enter and the script opens it;
   don't touch it. Nothing is launched over it at first, but nobody can leave it without a
   controller, so $TARGET comes back over it within about 45 s." "6. Loader screen left open" || return 0
    mark=$(capture_mark)
    adb_shell am start -n "$LOADER_MAIN" >/dev/null 2>&1 || true
    sleep 15
    if is_foreground "$TARGET" 2>/dev/null && [[ -n "$(relaunch_lines "$mark")" ]]; then
        early="relaunched within 15 s, over the loader's screen"
    else
        early="nothing launched in the first 15 s"
    fi
    back=$(watch_front 60) || true
    say "   $early; then $TARGET $back"
    record "6. Loader screen left open" "$early" "then $TARGET $back" "$(relaunch_summary "$mark")"
}
check_restart() {
    local how=$1 title=$2 mark old took result
    mark=$(capture_mark)
    old=$(boot_id)
    if [[ $how == adb ]]; then
        pause_for "== Check $title: press Enter and the script restarts the headset with adb reboot
   (like a power cut). Then wait; the script times the start." "$title" || return 0
        adb_ reboot >/dev/null 2>&1 || true
    else
        pause_for "== Check $title: turn the headset off with its power button: hold it until the
   headset turns off (if a power menu appears, keep holding). Then press the power button once to
   turn it on, and press Enter here right away. The script times the start." "$title" || return 0
    fi
    say "   waiting for the headset to boot and adb to come back (up to 15 minutes)..."
    if ! took=$(wait_boot "$old" 900); then
        say "   adb didn't come back within 15 minutes"
        record "$title" "adb did not come back within 15 minutes (state: $(adb_state))" \
            "you: started by itself = $(ask_yn "Did $TARGET start by itself, with no input?")"
        return 0
    fi
    prox_on
    result=$(watch_front 180) || true
    say "   adb back ${took} s after the restart; $TARGET $result; $(boot_launch_line)"
    record "$title" "adb back ${took} s after the restart; $TARGET $result" "$(boot_launch_line)" "$(grants_line)" \
        "$(relaunch_summary "$mark")" \
        "you: started by itself = $(ask_yn "Did $TARGET start by itself, with no input?")"
}

check_permission_prompt() {
    local has
    has=$(ask_yn "== Check 9 (optional): does $TARGET ever show a permission prompt (microphone, storage, ...)?")
    if [[ $has != y ]]; then
        record "9. Permission prompt" "target shows a prompt = $has"
        return 0
    fi
    pause_for "   Make the prompt appear, leave it open for 15 s without answering, then press Enter." \
        "9. Permission prompt" || return 0
    record "9. Permission prompt" \
        "you: the watchdog closed the prompt = $(ask_yn "Did the prompt disappear (the target was relaunched over it)?")" \
        "you: note = $(ask "Anything else (Enter to skip)?")"
}

pack() {
    local zip
    [[ $PACKED == no ]] || return 0
    PACKED=yes
    stop_capture
    if [[ $PROX_OVERRIDE == yes ]]; then prox_off; fi
    [[ -d $OUT ]] || return 0
    if [[ $SUMMARY_READY == no ]]; then
        record "Run" "stopped before the end; what was collected is included"
    fi
    if command -v zip >/dev/null; then
        zip="$OUT.zip"
        (cd "$(dirname "$OUT")" && zip -qr "$zip" "$(basename "$OUT")")
    else
        zip="$OUT.tar.gz"
        tar -czf "$zip" -C "$(dirname "$OUT")" "$(basename "$OUT")"
    fi
    echo
    echo "Everything is in $zip"
    echo "Upload that file in the chat with Claude."
}

main() {
    parse_args "$@"
    find_adb
    mkdir -p "$OUT"
    RUN_LOG=$OUT/quest-check.log
    : >"$RUN_LOG"
    pick_device
    trap pack EXIT
    trap 'echo; echo "Stopped."; exit 130' INT TERM
    printf '# Quest check\n\nTarget: %s\nStarted: %s\n' "$TARGET" "$(date '+%Y-%m-%d %H:%M:%S %Z')" >"$OUT/checks.md"

    say "Headset: $(device_prop ro.product.manufacturer) $(device_prop ro.product.model), $(device_prop ro.build.display.id) (Android $(device_prop ro.build.version.release)), serial $E2E_SERIAL"
    if device_is_emulator; then say "Note: this is an emulator, not a headset."; fi
    target_installed || die "$TARGET is not installed on the headset. Install it first (adb install -g <apk> also grants its permissions)."
    device_info
    if ! hand_tracking_declared; then
        say "Note: $TARGET doesn't ask for hand tracking. Horizon OS may then refuse to start it"
        say "without an active controller, showing its 'controllers required' dialog instead. The"
        say "checks report it if that happens."
    fi
    say "Set the headset up as users get it: controllers off and away, hand tracking off."

    if [[ $(ask_yn "Keep the display on while nobody wears the headset (undone at the end and for check 5)?") == y ]]; then
        PROX_OVERRIDE=yes
        prox_on
    fi

    if [[ $SKIP_SUITE == no ]]; then run_suite; fi
    provision_real_target
    start_capture

    say ""
    say "== Part C: the checks. Each one says what to do; s skips it."
    check_first_start
    check_exit
    check_crash
    check_power_button
    check_headset_off
    check_loader_ui
    check_restart power "7. Power off and on with the power button"
    check_restart adb "8. adb reboot"
    check_permission_prompt

    SUMMARY_READY=yes
    record "Run" "finished: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        "you: overall note = $(ask "Anything else about how it behaved (Enter to skip)?")"
    say ""
    say "Done. The headset stays provisioned for $TARGET."
}

main "$@"
