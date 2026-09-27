#!/usr/bin/env bash
# End-to-end tests for the loader, black box: installs the real loader APK and two test target
# apps on an Android emulator (or, deliberately, a headset), provisions it the way a Quest is
# provisioned, then checks from the outside that the watchdog launches, relaunches and stands down
# when it should. See e2e/README.md.
#
# Usage: e2e/run.sh [options]   (e2e/run.sh --help lists them, e2e/run.sh --list the scenarios)
set -euo pipefail

E2E_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "$E2E_DIR/.." && pwd -P)
# shellcheck source=SCRIPTDIR/lib.sh
source "$E2E_DIR/lib.sh"

# Scenarios in the order they run: "name|what it proves". The names are what --only, --skip and
# CI use; each one runs as the function scenario_<name with - replaced by _>.
SCENARIOS=(
    "provision|scripts/provision-quest.sh installs and grants the loader, sets the target and starts the watchdog"
    "loader-ui-stands-down|nothing is launched while the loader UI is in front"
    "launches-target|leaving the loader UI (HOME) gets the target launched"
    "relaunch-after-exit|the target comes back after a normal exit"
    "relaunch-after-crash|the target comes back, in a new process, after a crash"
    "relaunch-after-force-stop|the target comes back after am force-stop"
    "relaunch-after-home|the target comes back after HOME (the Meta button)"
    "grace-period|the relaunch waits for the configured grace period"
    "pause-resume|PAUSE stops relaunches, RESUME brings them back"
    "disable-enable|DISABLE stops relaunches, ENABLE brings them back"
    "screen-off|nothing is relaunched while the display is off; the target comes back after wake"
    "set-target-validation|SET_TARGET rejects a package that isn't installed and keeps the old target"
    "admin-receiver-protected|an ordinary app can't send admin commands to the loader"
    "vr-target|a VR-only app (no LAUNCHER category) can be the target"
    "blind-mode|without usage access the target still comes back (30 s blind relaunch)"
    "package-replaced|updating the loader restarts the watchdog without opening the UI"
    "reboot|after a reboot the target starts with no interaction"
    "crash-loop-backoff|a crash loop gets throttled, and the target comes back after the cooldown"
)

# Timing. Emulators in CI render in software and are slow, so waits are generous.
BACK_TIMEOUT=${E2E_BACK_TIMEOUT:-30} # the target comes back after an exit (grace 3 s + 2 s ticks)
FAST_GRACE=3                         # grace period used by the scenarios, for speed
STAND_DOWN_S=12                      # how long "nothing happens" is watched
SCREEN_OFF_GRACE=6                   # see scenario_screen_off
BLIND_TIMEOUT=55                     # grace + 30 s blind interval + margin
REBOOT_TIMEOUT=120                   # target resumed after boot completed
MAX_CRASHES=8
MAX_LAUNCHES=5      # LaunchBackoff: 5 launches in 3 minutes, then one per minute
COOLDOWN_TIMEOUT=80 # LaunchBackoff: one launch per 60 s once throttled
NO_CLOCK="can't read the device clock (device offline?)"
NO_EXIT="the test app did not log EXIT (command not delivered?)"

OPT_SERIAL=""
OPT_LOADER_APK=app/build/outputs/apk/debug/app-debug.apk
OPT_TARGET_APK=testapp/build/outputs/apk/launcher/debug/testapp-launcher-debug.apk
OPT_VR_TARGET_APK=testapp/build/outputs/apk/vr/debug/testapp-vr-debug.apk
OPT_RESULTS=e2e/results
OPT_ONLY=""
OPT_SKIP=""
OPT_LIST=no
OPT_ALLOW_REAL=no

LOADER_APK=""
TARGET_APK=""
VR_TARGET_APK=""
RESULTS_DIR=""
SELECTED=()
R_NAMES=()
R_RESULTS=()
R_SECS=()
R_NOTES=()
CURRENT_SCENARIO=""
CURRENT_START=0
SCENARIO_MARK=""
ABORT_REASON=""
FINALIZED=no
FRESH_WATCHDOG=no # the service was just (re)started, so its launch backoff history is empty
RUN_TIMESTAMP=""
DEVICE_KIND=""
DEVICE_SDK=""
DEVICE_RELEASE=""
DEVICE_MODEL=""

# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: e2e/run.sh [options]

Runs the end-to-end suite against the real loader APK on an Android emulator. The device gets
the loader and the test apps reinstalled, some settings changed, and is rebooted once.

Options:
  --serial SERIAL        adb serial (default: $ANDROID_SERIAL, else the only device attached)
  --loader-apk PATH      loader APK (default: app/build/outputs/apk/debug/app-debug.apk)
  --target-apk PATH      launcher test app
                         (default: testapp/build/outputs/apk/launcher/debug/testapp-launcher-debug.apk)
  --vr-target-apk PATH   VR-only test app
                         (default: testapp/build/outputs/apk/vr/debug/testapp-vr-debug.apk)
  --results DIR          reports and logs (default: e2e/results)
  --only a,b             run only these scenarios (provision always runs first)
  --skip a,b             skip these scenarios
  --list                 list the scenarios and exit
  --allow-real-device    allow a device that isn't an emulator, e.g. a Quest: it gets the
                         loader uninstalled, settings changed and a reboot
  -h, --help             show this help

Relative paths are resolved against the repository root. Build the APKs first:
  ./gradlew testDebugUnitTest assembleDebug :testapp:assembleDebug

Exit status: 0 if every selected scenario passed, 1 if one failed, 2 on usage or setup errors.
EOF
}

usage_error() {
    printf 'e2e/run.sh: %s\nRun e2e/run.sh --help for the options.\n' "$*" >&2
    exit 2
}

set_opt() {
    [[ -n $2 ]] || usage_error "$1 needs a value"
    case $1 in
    --serial) OPT_SERIAL=$2 ;;
    --loader-apk) OPT_LOADER_APK=$2 ;;
    --target-apk) OPT_TARGET_APK=$2 ;;
    --vr-target-apk) OPT_VR_TARGET_APK=$2 ;;
    --results) OPT_RESULTS=$2 ;;
    --only) OPT_ONLY=$2 ;;
    --skip) OPT_SKIP=$2 ;;
    esac
}

parse_args() {
    while (($# > 0)); do
        case $1 in
        --serial | --loader-apk | --target-apk | --vr-target-apk | --results | --only | --skip)
            (($# >= 2)) || usage_error "$1 needs a value"
            set_opt "$1" "$2"
            shift 2
            ;;
        --serial=* | --loader-apk=* | --target-apk=* | --vr-target-apk=* | --results=* | --only=* | --skip=*)
            set_opt "${1%%=*}" "${1#*=}"
            shift
            ;;
        --list)
            OPT_LIST=yes
            shift
            ;;
        --allow-real-device)
            OPT_ALLOW_REAL=yes
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) usage_error "unknown option: $1" ;;
        esac
    done
}

scenario_name() { printf '%s\n' "${1%%|*}"; }

scenario_desc() {
    local entry
    for entry in "${SCENARIOS[@]}"; do
        if [[ ${entry%%|*} == "$1" ]]; then
            printf '%s\n' "${entry#*|}"
            return 0
        fi
    done
    return 1
}

list_scenarios() {
    local entry i=0
    for entry in "${SCENARIOS[@]}"; do
        i=$((i + 1))
        printf '%2d  %-26s %s\n' "$i" "${entry%%|*}" "${entry#*|}"
    done
}

# csv_items CSV: the non-empty items, one per line
csv_items() {
    printf '%s\n' "$1" | tr ',' '\n' | tr -d ' \t' | grep -v '^$' || true
}

# csv_has CSV NAME
csv_has() {
    [[ ",$(printf '%s' "$1" | tr -d ' \t')," == *",$2,"* ]]
}

# select_scenarios ONLY_CSV SKIP_CSV: the scenarios to run, in suite order. provision always
# runs: every run reinstalls the loader, and the other scenarios start from a provisioned device.
select_scenarios() {
    local only=$1 skip=$2 item entry name
    while IFS= read -r item; do
        if [[ -n $item ]] && ! scenario_desc "$item" >/dev/null; then
            printf 'e2e/run.sh: unknown scenario "%s" (e2e/run.sh --list shows them)\n' "$item" >&2
            return 2
        fi
    done <<<"$(
        csv_items "$only"
        csv_items "$skip"
    )"
    if csv_has "$skip" provision; then
        printf 'e2e/run.sh: provision cannot be skipped: every run reinstalls the loader and the other scenarios need it\n' >&2
        return 2
    fi
    for entry in "${SCENARIOS[@]}"; do
        name=${entry%%|*}
        if [[ -n $only && $name != provision ]] && ! csv_has "$only" "$name"; then continue; fi
        if csv_has "$skip" "$name"; then continue; fi
        printf '%s\n' "$name"
    done
}

abs_path() {
    case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$REPO_ROOT/$1" ;;
    esac
}

rel_path() {
    case $1 in
    "$REPO_ROOT"/*) printf '%s\n' "${1#"$REPO_ROOT"/}" ;;
    *) printf '%s\n' "$1" ;;
    esac
}

# ---------------------------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------------------------

record_result() {
    R_NAMES+=("$1")
    R_RESULTS+=("$2")
    R_SECS+=("$3")
    R_NOTES+=("$4")
}

result_recorded() {
    local name
    for name in "${R_NAMES[@]+"${R_NAMES[@]}"}"; do
        if [[ $name == "$1" ]]; then return 0; fi
    done
    return 1
}

count_failures() {
    local result n=0
    for result in "${R_RESULTS[@]+"${R_RESULTS[@]}"}"; do
        if [[ $result != pass ]]; then n=$((n + 1)); fi
    done
    printf '%s\n' "$n"
}

# record_not_run REASON: every selected scenario without a result fails with REASON
record_not_run() {
    local name
    for name in "${SELECTED[@]+"${SELECTED[@]}"}"; do
        if ! result_recorded "$name"; then record_result "$name" fail 0 "not run: $1"; fi
    done
}

device_title() {
    if [[ -z $E2E_SERIAL ]]; then
        printf 'no device\n'
    elif [[ -n $DEVICE_SDK ]]; then
        printf 'API %s (Android %s, %s, %s)\n' "$DEVICE_SDK" "$DEVICE_RELEASE" "${DEVICE_MODEL:-unknown model}" "$E2E_SERIAL"
    else
        printf '%s\n' "$E2E_SERIAL"
    fi
}

write_junit() {
    local file=$RESULTS_DIR/junit.xml n=${#R_NAMES[@]} i failures total=0 classname message body
    failures=$(count_failures)
    for ((i = 0; i < n; i++)); do total=$((total + R_SECS[i])); done
    classname=e2e.api${DEVICE_SDK:-unknown}
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuites name="kiosk-launcher-e2e" tests="%d" failures="%d" errors="0" time="%d">\n' \
            "$n" "$failures" "$total"
        printf '  <testsuite name="%s" tests="%d" failures="%d" errors="0" skipped="0" time="%d" timestamp="%s" hostname="%s">\n' \
            "$(xml_escape "kiosk-launcher-e2e.api${DEVICE_SDK:-unknown}")" "$n" "$failures" "$total" \
            "$(xml_escape "$RUN_TIMESTAMP")" "$(xml_escape "${E2E_SERIAL:-none}")"
        printf '    <properties>\n'
        printf '      <property name="device" value="%s"/>\n' "$(xml_escape "$(device_title)")"
        printf '      <property name="loader_apk" value="%s"/>\n' "$(xml_escape "$(rel_path "$LOADER_APK")")"
        printf '    </properties>\n'
        for ((i = 0; i < n; i++)); do
            if [[ ${R_RESULTS[i]} == pass ]]; then
                printf '    <testcase classname="%s" name="%s" time="%d"/>\n' \
                    "$classname" "$(xml_escape "${R_NAMES[i]}")" "${R_SECS[i]}"
            else
                message=$(one_line "${R_NOTES[i]}")
                body="${R_NOTES[i]}"
                if [[ ${R_NOTES[i]} != "not run: "* ]]; then
                    body+=$'\n'"See logcat-${R_NAMES[i]}.txt, screenshot-${R_NAMES[i]}.png and dumpsys-${R_NAMES[i]}.txt in the results."
                fi
                printf '    <testcase classname="%s" name="%s" time="%d">\n' \
                    "$classname" "$(xml_escape "${R_NAMES[i]}")" "${R_SECS[i]}"
                printf '      <failure message="%s" type="ScenarioFailure">%s</failure>\n' \
                    "$(xml_escape "$message")" "$(xml_escape "$body")"
                printf '    </testcase>\n'
            fi
        done
        printf '  </testsuite>\n'
        printf '</testsuites>\n'
    } >"$file.tmp"
    mv -f "$file.tmp" "$file"
}

write_summary() {
    local file=$RESULTS_DIR/summary.md n=${#R_NAMES[@]} i failures result
    failures=$(count_failures)
    {
        printf '### Kiosk Launcher e2e: %s\n\n' "$(md_cell "$(device_title)")"
        if [[ -n $ABORT_REASON ]]; then
            printf '**Run stopped:** %s\n\n' "$(md_cell "$ABORT_REASON")"
        fi
        printf '| Scenario | Result | Seconds | Note |\n'
        printf '| --- | --- | --- | --- |\n'
        for ((i = 0; i < n; i++)); do
            if [[ ${R_RESULTS[i]} == pass ]]; then result=pass; else result='**FAIL**'; fi
            printf '| %s | %s | %s | %s |\n' "${R_NAMES[i]}" "$result" "${R_SECS[i]}" "$(md_cell "${R_NOTES[i]}")"
        done
        printf '\n%d of %d scenarios passed. Loader APK: %s\n' "$((n - failures))" "$n" "$(md_cell "$(rel_path "$LOADER_APK")")"
    } >"$file.tmp"
    mv -f "$file.tmp" "$file"
}

write_reports() {
    write_junit || log "could not write junit.xml"
    write_summary || log "could not write summary.md"
}

finalize() {
    if [[ $FINALIZED == yes ]]; then return 0; fi
    FINALIZED=yes
    write_reports
    local files=(junit.xml summary.md run.log)
    if [[ -n $E2E_SERIAL ]] && device_online &&
        adb_ logcat -d -v threadtime >"$RESULTS_DIR/logcat.txt" 2>/dev/null; then
        files+=(logcat.txt)
    fi
    log "reports in $(rel_path "$RESULTS_DIR"): ${files[*]}"
}

# abort_run REASON: a problem that stops the whole run (no device, missing APK, ...)
abort_run() {
    log "ERROR: $1"
    ABORT_REASON=$1
    record_not_run "$1"
    finalize
    exit 2
}

on_signal() {
    trap - INT TERM
    log "interrupted"
    if [[ -n $CURRENT_SCENARIO ]]; then
        record_result "$CURRENT_SCENARIO" fail $((SECONDS - CURRENT_START)) "interrupted"
        CURRENT_SCENARIO=""
    fi
    ABORT_REASON=interrupted
    record_not_run interrupted
    exit 130
}

on_exit() {
    finalize || true
}

# ---------------------------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------------------------

clean_results() {
    rm -f "$RESULTS_DIR"/junit.xml "$RESULTS_DIR"/summary.md "$RESULTS_DIR"/run.log \
        "$RESULTS_DIR"/provision.log "$RESULTS_DIR"/logcat*.txt "$RESULTS_DIR"/screenshot-*.png \
        "$RESULTS_DIR"/dumpsys-*.txt
}

check_apks() {
    local apk missing=()
    for apk in "$LOADER_APK" "$TARGET_APK" "$VR_TARGET_APK"; do
        if [[ ! -f $apk ]]; then missing+=("$(rel_path "$apk")"); fi
    done
    if ((${#missing[@]} > 0)); then
        abort_run "APK not found: ${missing[*]}. Build them with ./gradlew testDebugUnitTest assembleDebug :testapp:assembleDebug, or pass their paths"
    fi
}

find_adb() {
    local sdk found=""
    if command -v adb >/dev/null 2>&1; then
        found=$(command -v adb)
    else
        for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
            if [[ -n $sdk && -x $sdk/platform-tools/adb ]]; then
                found=$sdk/platform-tools/adb
                break
            fi
        done
    fi
    if [[ -z $found ]]; then
        abort_run "adb not found: put the Android SDK platform-tools on PATH or set ANDROID_HOME"
    fi
    ADB=$found
    # scripts/provision-quest.sh runs plain `adb`: make sure it is this one
    PATH="$(dirname "$ADB"):$PATH"
    export PATH
}

pick_device() {
    local serial=${OPT_SERIAL:-${ANDROID_SERIAL:-}} devices online others count state
    if [[ -z $serial ]]; then
        devices=$("$ADB" devices 2>/dev/null </dev/null) || abort_run "'adb devices' failed"
        online=$(printf '%s\n' "$devices" | awk 'NR > 1 && $2 == "device" { print $1 }')
        others=$(printf '%s\n' "$devices" |
            awk 'NR > 1 && NF >= 2 && $2 != "device" { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
        count=$(printf '%s\n' "$online" | awk 'NF { n++ } END { print n + 0 }')
        if ((count == 0)); then
            if [[ -n $others ]]; then
                abort_run "no usable device: $others. Check the device or restart it"
            fi
            abort_run "no device attached. Start an emulator (e2e/start-emulator.sh), or connect a headset and pass --allow-real-device"
        fi
        if ((count > 1)); then
            abort_run "several devices attached ($(printf '%s' "$online" | tr '\n' ' ')): pick one with --serial or ANDROID_SERIAL"
        fi
        serial=$online
    fi
    E2E_SERIAL=$serial
    state=$("$ADB" -s "$serial" get-state 2>&1 </dev/null) || true
    if [[ $state != device ]]; then
        abort_run "device $serial is not available (adb get-state: $(one_line "$state"))"
    fi
}

check_device_kind() {
    if device_is_emulator; then
        DEVICE_KIND=emulator
        return 0
    fi
    DEVICE_KIND=device
    if [[ $OPT_ALLOW_REAL != yes ]]; then
        abort_run "$E2E_SERIAL is not an emulator. The suite uninstalls the loader, changes settings (screen stays on, no lock screen, no error dialogs) and reboots the device. Pass --allow-real-device to run it on a real headset anyway"
    fi
    log "WARNING: $E2E_SERIAL is a real device: the loader gets reinstalled, settings changed and the device rebooted"
}

setup_device() {
    local pkg apk out
    step "uninstalling the loader and the test apps"
    for pkg in "$LOADER_PKG" "$TARGET_PKG" "$VR_TARGET_PKG"; do
        adb_ uninstall "$pkg" >>"$RUN_LOG" 2>&1 || true
    done
    for apk in "$TARGET_APK" "$VR_TARGET_APK"; do
        step "installing $(rel_path "$apk")"
        out=$(adb_ install -r -t "$apk" 2>&1) || true
        detail "$out"
        if [[ $out != *Success* ]]; then
            log "install of $(rel_path "$apk") failed: $(one_line "$out")"
            return 1
        fi
    done
    for pkg in "$TARGET_PKG" "$VR_TARGET_PKG"; do
        if ! package_installed "$pkg"; then
            log "$pkg is not installed after installing the test APKs (wrong applicationId?)"
            return 1
        fi
    done
    adb_ logcat -c >/dev/null 2>&1 || true
    return 0
}

# ---------------------------------------------------------------------------------------------
# Running scenarios
# ---------------------------------------------------------------------------------------------

capture_failure_artifacts() {
    local name=$1 since=$2 dir=$RESULTS_DIR
    step "saving logcat, screenshot and dumpsys for $name"
    if [[ -n $since && $LOGCAT_SINCE == yes ]]; then
        adb_ logcat -d -v threadtime -t "$since" >"$dir/logcat-$name.txt" 2>&1 || true
    else
        adb_ logcat -d -v threadtime >"$dir/logcat-$name.txt" 2>&1 || true
    fi
    if ! adb_ exec-out screencap -p >"$dir/screenshot-$name.png" 2>/dev/null; then
        rm -f "$dir/screenshot-$name.png"
    fi
    {
        printf '# foreground: %s\n' "$(foreground_pkg)"
        printf '# display: %s\n' "$(wakefulness)"
        printf '# pids: target=%s vr-target=%s loader=%s\n' \
            "$(pid_of "$TARGET_PKG")" "$(pid_of "$VR_TARGET_PKG")" "$(pid_of "$LOADER_PKG")"
        printf '\n# run-as %s cat shared_prefs/loader.xml\n' "$LOADER_PKG"
        prefs_xml || true
        printf '\n# appops get %s\n' "$LOADER_PKG"
        adb_shell appops get "$LOADER_PKG" || true
        printf '\n# dumpsys activity activities\n'
        adb_shell dumpsys activity activities || true
        printf '\n# dumpsys activity services %s\n' "$LOADER_PKG"
        adb_shell dumpsys activity services "$LOADER_PKG" || true
    } >"$dir/dumpsys-$name.txt" 2>&1
}

# restore_sane_state: best effort after a failure, so the next scenario starts from the usual
# state: target = launcher test app, enabled, not paused, grace 3 s, usage access, screen on
restore_sane_state() {
    local used
    if ! device_online; then
        step "the device is offline, nothing to restore"
        return 0
    fi
    step "restoring the usual state"
    wake_device
    if ! package_installed "$LOADER_PKG"; then
        adb_ install -r -g "$LOADER_APK" >>"$RUN_LOG" 2>&1 || true
        adb_shell dumpsys deviceidle whitelist "+$LOADER_PKG" >/dev/null 2>&1 || true
    fi
    adb_shell appops set "$LOADER_PKG" SYSTEM_ALERT_WINDOW allow >/dev/null 2>&1 || true
    adb_shell appops set "$LOADER_PKG" GET_USAGE_STATS allow >/dev/null 2>&1 || true
    admin_try SET_TARGET --es package "$TARGET_PKG" || true
    admin_try ENABLE || true
    admin_try RESUME || true
    admin_try SET_GRACE --ei seconds "$FAST_GRACE" || true
    force_stop "$VR_TARGET_PKG"
    used=$(recent_launches) || used=0
    if ((used >= MAX_LAUNCHES)) || ! watchdog_running; then
        # A new service instance: running, and with an empty launch backoff
        force_stop "$LOADER_PKG"
        open_loader_ui || true
        wait_until 30 watchdog_running || true
    fi
    if is_foreground "$LOADER_PKG"; then press_key KEYCODE_HOME; fi
    if ! wait_until 30 is_foreground "$TARGET_PKG"; then
        step "the target is still not in front after restoring"
    fi
}

ensure_device_online() {
    if device_online; then return 0; fi
    log "device $E2E_SERIAL is offline, waiting up to 120 s"
    wait_until 120 boot_ready
}

# run_scenario NAME INDEX TOTAL
run_scenario() {
    local name=$1 fn secs ok=no
    fn=scenario_${name//-/_}
    E2E_FAIL_REASON=""
    E2E_NOTE=""
    log "==> [$2/$3] $name: $(scenario_desc "$name")"
    if ! ensure_device_online; then
        ABORT_REASON="device $E2E_SERIAL went offline"
        record_result "$name" fail 0 "$ABORT_REASON"
        log "FAIL $name: $ABORT_REASON"
        return 1
    fi
    CURRENT_SCENARIO=$name
    CURRENT_START=$SECONDS
    if SCENARIO_MARK=$(log_mark "scenario $name"); then
        if "$fn"; then ok=yes; fi
    else
        SCENARIO_MARK=""
        fail "$NO_CLOCK" || true
    fi
    if [[ -n $E2E_FAIL_REASON ]]; then ok=no; fi
    secs=$((SECONDS - CURRENT_START))
    CURRENT_SCENARIO=""
    if [[ $ok == yes ]]; then
        record_result "$name" pass "$secs" "$E2E_NOTE"
        log "PASS $name (${secs} s)"
    else
        if [[ -z $E2E_FAIL_REASON ]]; then E2E_FAIL_REASON="the scenario returned an error"; fi
        record_result "$name" fail "$secs" "$E2E_FAIL_REASON"
        log "FAIL $name (${secs} s): $E2E_FAIL_REASON"
        capture_failure_artifacts "$name" "$SCENARIO_MARK" || true
        restore_sane_state || true
    fi
    write_reports
    [[ $ok == yes ]]
}

# ---------------------------------------------------------------------------------------------
# Scenario helpers
# ---------------------------------------------------------------------------------------------

# require_target_foreground: the usual starting point, the launcher test app in front
require_target_foreground() {
    local fg
    if ! is_awake; then wake_device; fi
    fg=$(foreground_pkg)
    if [[ $fg == "$TARGET_PKG" ]]; then return 0; fi
    step "the target is not in front (foreground: ${fg:-none}), waiting for the watchdog"
    if [[ $fg == "$LOADER_PKG" ]]; then press_key KEYCODE_HOME; fi
    if wait_until 60 is_foreground "$TARGET_PKG"; then return 0; fi
    fg=$(foreground_pkg)
    fail "precondition: the target app is not in the foreground (foreground: ${fg:-none})"
}

# exit_target SINCE: sends EXIT, prints when the test app logged it
exit_target() {
    target_cmd EXIT || true
    wait_for_log_ts 10 "$1" "$TARGET_TAG" "$(target_event_re EXIT "$TARGET_PKG")"
}

watchdog_restarted() { # OLD_LOADER_PID
    local pid
    pid=$(pid_of "$LOADER_PKG")
    [[ -n $pid && $pid != "$1" ]] && watchdog_running
}

old_boot_gone() { # OLD_BOOT_ID
    local id
    if ! device_online; then return 0; fi
    if [[ "$(device_prop sys.boot_completed)" != 1 ]]; then return 0; fi
    if [[ -n $1 ]]; then
        id=$(boot_id)
        if [[ -n $id && $id != "$1" ]]; then return 0; fi
    fi
    return 1
}

new_boot_ready() { # OLD_BOOT_ID
    local id
    boot_ready || return 1
    if [[ -n $1 ]]; then
        id=$(boot_id)
        [[ -n $id && $id != "$1" ]] || return 1
    fi
    return 0
}

# restart_watchdog [ui]: force-stops the loader and opens its UI, which starts a new
# WatchdogService with an empty launch history. Then presses HOME, so the target comes back,
# unless "ui" is given.
restart_watchdog() {
    force_stop "$LOADER_PKG"
    expect_within 15 "WatchdogService still running after am force-stop" watchdog_stopped || return 1
    open_loader_ui || {
        fail "the loader UI did not open"
        return 1
    }
    expect_within 30 "WatchdogService did not start with the loader UI" watchdog_running || return 1
    if [[ ${1:-} != ui ]]; then press_key KEYCODE_HOME; fi
}

# ensure_launch_budget N [ui]: makes sure the watchdog can launch N more times without being
# throttled. LaunchBackoff allows 5 launches in 3 minutes per service instance, then one per
# minute, and the scenarios relaunch the target every few seconds: without this, the later ones
# would hit the crash-loop backoff (crash-loop-backoff tests that on purpose). When the budget
# is used up, the loader is restarted, which gives a new service instance. [ui]: see
# restart_watchdog.
ensure_launch_budget() {
    local need=$1 used
    # One more if the watchdog first has to bring the target back
    if ! is_foreground "$TARGET_PKG"; then need=$((need + 1)); fi
    used=$(recent_launches) || used=0
    if ((used + need <= MAX_LAUNCHES)); then return 0; fi
    step "the watchdog launched $used times in the last 3 minutes; restarting the loader so its crash-loop backoff doesn't throttle this scenario"
    restart_watchdog "${2:-}" || return 1
    note "loader restarted first (launch backoff)"
}

back_or_throttled() { # SINCE OLD_TARGET_PID
    local pid
    if log_has "$1" WatchdogService "$(re_escape "$TARGET_PKG") keeps exiting, relaunch throttled"; then
        return 0
    fi
    pid=$(pid_of "$TARGET_PKG")
    [[ -n $pid && $pid != "$2" ]] && is_foreground "$TARGET_PKG"
}

restore_usage_access() {
    adb_shell appops set "$LOADER_PKG" GET_USAGE_STATS allow >/dev/null 2>&1 || true
    [[ "$(appops_mode "$LOADER_PKG" GET_USAGE_STATS)" == allow ]]
}

# ---------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------

scenario_provision() {
    local rc=0 mode log_file=$RESULTS_DIR/provision.log
    step "scripts/provision-quest.sh $(rel_path "$LOADER_APK") $TARGET_PKG $E2E_SERIAL"
    bash "$REPO_ROOT/scripts/provision-quest.sh" "$LOADER_APK" "$TARGET_PKG" "$E2E_SERIAL" \
        >"$log_file" 2>&1 </dev/null || rc=$?
    sed 's/^/      | /' "$log_file" >>"$RUN_LOG" 2>/dev/null || true
    if ((rc != 0)); then
        fail "provision-quest.sh exited with $rc: $(one_line "$(tail -n 3 "$log_file")")"
        return 1
    fi
    mode=$(appops_mode "$LOADER_PKG" SYSTEM_ALERT_WINDOW)
    if [[ $mode != allow ]]; then
        fail "appops SYSTEM_ALERT_WINDOW of the loader is '${mode:-unset}', expected allow"
        return 1
    fi
    mode=$(appops_mode "$LOADER_PKG" GET_USAGE_STATS)
    if [[ $mode != allow ]]; then
        fail "appops GET_USAGE_STATS of the loader is '${mode:-unset}', expected allow"
        return 1
    fi
    if ! in_deviceidle_whitelist "$LOADER_PKG"; then
        fail "the loader is not in the deviceidle whitelist"
        return 1
    fi
    expect_pref target_package "$TARGET_PKG" || return 1
    expect_foreground "$LOADER_PKG" 30 "the loader UI (MainActivity)" || return 1
    expect_within 30 "WatchdogService is not running as a foreground service" watchdog_running || return 1
    if ! wait_for_log_ts 10 "$SCENARIO_MARK" WatchdogService "Watchdog started" >/dev/null; then
        fail "no 'Watchdog started' in the log"
        return 1
    fi
    admin_cmd SET_GRACE --ei seconds "$FAST_GRACE" || return 1
    expect_pref grace_seconds "$FAST_GRACE" || return 1
}

scenario_loader_ui_stands_down() {
    local since fg pid
    if ! is_foreground "$LOADER_PKG"; then
        step "opening the loader UI"
        open_loader_ui || {
            fail "the loader UI did not come to the front"
            return 1
        }
    fi
    if ! watchdog_running; then
        fail "WatchdogService is not running"
        return 1
    fi
    if [[ -n "$(pid_of "$TARGET_PKG")" ]]; then
        step "stopping the target first, so that a launch would show"
        force_stop "$TARGET_PKG"
    fi
    since=$(log_mark "loader UI in front") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "waiting ${STAND_DOWN_S} s with the loader UI in front"
    sleep "$STAND_DOWN_S"
    fg=$(foreground_pkg)
    if [[ $fg != "$LOADER_PKG" ]]; then
        fail "the loader UI is no longer in front (foreground: ${fg:-none})"
        return 1
    fi
    if log_has "$since" WatchdogService "Relaunching"; then
        fail "the watchdog relaunched the target while the loader UI was in front"
        return 1
    fi
    pid=$(pid_of "$TARGET_PKG")
    if [[ -n $pid ]]; then
        fail "the target was started while the loader UI was in front (pid $pid)"
        return 1
    fi
}

scenario_launches_target() {
    local since pkg_re
    pkg_re=$(re_escape "$TARGET_PKG")
    ensure_launch_budget 1 ui || return 1
    if ! is_foreground "$LOADER_PKG"; then
        step "opening the loader UI"
        open_loader_ui || {
            fail "the loader UI did not come to the front"
            return 1
        }
    fi
    if [[ -n "$(pid_of "$TARGET_PKG")" ]]; then force_stop "$TARGET_PKG"; fi
    since=$(log_mark "HOME from the loader UI") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "pressing HOME to leave the loader UI"
    press_key KEYCODE_HOME
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" "launched" || return 1
    if ! log_has "$since" TargetLauncher "Launched $pkg_re\$"; then
        fail "TargetLauncher did not log 'Launched $TARGET_PKG'"
        return 1
    fi
    if ! log_has "$since" "$TARGET_TAG" "$(target_event_re CREATED "$TARGET_PKG")"; then
        fail "the test app did not log CREATED"
        return 1
    fi
}

scenario_relaunch_after_exit() {
    local since exit_ts
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    since=$(log_mark "EXIT") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_within 15 "the target did not leave the foreground after EXIT" \
        target_left_since "$since" "$TARGET_PKG" || return 1
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

scenario_relaunch_after_crash() {
    local since old_pid new_pid crash_ts
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    old_pid=$(pid_of "$TARGET_PKG")
    if [[ -z $old_pid ]]; then
        fail "the target has no process"
        return 1
    fi
    since=$(log_mark "CRASH") || {
        fail "$NO_CLOCK"
        return 1
    }
    target_cmd CRASH || true
    crash_ts=$(wait_for_log_ts 10 "$since" "$TARGET_TAG" "$(target_event_re CRASH "$TARGET_PKG")") || {
        fail "the test app did not log CRASH (command not delivered?)"
        return 1
    }
    expect_within 15 "process $old_pid is still alive after CRASH" pid_not "$TARGET_PKG" "$old_pid" || return 1
    expect_relaunch "$crash_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
    new_pid=$(pid_of "$TARGET_PKG")
    if [[ -z $new_pid || $new_pid == "$old_pid" ]]; then
        fail "the target is back but its pid is '${new_pid:-none}' (was $old_pid)"
        return 1
    fi
    note "pid $old_pid -> $new_pid"
}

scenario_relaunch_after_force_stop() {
    local since old_pid new_pid
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    old_pid=$(pid_of "$TARGET_PKG")
    if [[ -z $old_pid ]]; then
        fail "the target has no process"
        return 1
    fi
    since=$(log_mark "force-stop") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "am force-stop $TARGET_PKG"
    force_stop "$TARGET_PKG"
    expect_within 15 "process $old_pid is still alive after am force-stop" \
        pid_not "$TARGET_PKG" "$old_pid" || return 1
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
    new_pid=$(pid_of "$TARGET_PKG")
    if [[ -z $new_pid || $new_pid == "$old_pid" ]]; then
        fail "the target is back but its pid is '${new_pid:-none}' (was $old_pid)"
        return 1
    fi
}

scenario_relaunch_after_home() {
    local since
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    since=$(log_mark "HOME over the target") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "pressing HOME"
    press_key KEYCODE_HOME
    expect_within 15 "the target did not leave the foreground after HOME" \
        target_left_since "$since" "$TARGET_PKG" || return 1
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

scenario_grace_period() {
    local since exit_ts rel_ts delay
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    admin_cmd SET_GRACE --ei seconds 12 || return 1
    expect_pref grace_seconds 12 || return 1
    since=$(log_mark "EXIT with a 12 s grace period") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_stays_away "$exit_ts" 6 "within 6 s of the exit with a 12 s grace period" || return 1
    expect_relaunch "$exit_ts" "$TARGET_PKG" $((12 + BACK_TIMEOUT)) || return 1
    rel_ts=$(log_first_ts "$exit_ts" WatchdogService "Relaunching $(re_escape "$TARGET_PKG") \\(") || rel_ts=""
    if [[ -n $rel_ts ]]; then
        delay=$(ts_diff "$rel_ts" "$exit_ts")
        if ts_lt "$delay" 11.5; then
            fail "relaunched ${delay} s after the exit, before the 12 s grace period was over"
            return 1
        fi
    fi
    admin_cmd SET_GRACE --ei seconds "$FAST_GRACE" || return 1
    expect_pref grace_seconds "$FAST_GRACE" || return 1
}

scenario_pause_resume() {
    local since exit_ts rel_ts
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    admin_cmd PAUSE --ei minutes 1 || return 1
    since=$(log_mark "paused for 1 minute") || {
        fail "$NO_CLOCK"
        return 1
    }
    expect_within 10 "paused_until was not set by PAUSE" pref_positive paused_until || return 1
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_stays_away "$exit_ts" "$STAND_DOWN_S" "while paused" || return 1
    admin_cmd RESUME || return 1
    expect_pref paused_until 0 || return 1
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
    rel_ts=$(log_first_ts "$exit_ts" WatchdogService "Relaunching $(re_escape "$TARGET_PKG") \\(") || rel_ts=""
    if [[ -n $rel_ts ]] && ! ts_lt "$(ts_diff "$rel_ts" "$since")" 55; then
        fail "the target only came back when the 1-minute pause ran out: RESUME had no effect"
        return 1
    fi
}

scenario_disable_enable() {
    local since exit_ts
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    admin_cmd DISABLE || return 1
    expect_pref enabled false || return 1
    since=$(log_mark "disabled") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_stays_away "$exit_ts" "$STAND_DOWN_S" "while disabled" || return 1
    admin_cmd ENABLE || return 1
    expect_pref enabled true || return 1
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

# The grace period is 6 s here, not 3: EXIT and KEYCODE_SLEEP go in one adb shell call, but
# `input` starts a JVM on API 29 and can take a couple of seconds on a CI emulator. A relaunch
# before the display is off would be a test race, not a loader bug. 12 s asleep is still twice
# the grace period, so a watchdog that ignored the display state would be caught.
scenario_screen_off() {
    local since wake_since
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    admin_cmd SET_GRACE --ei seconds "$SCREEN_OFF_GRACE" || return 1
    expect_pref grace_seconds "$SCREEN_OFF_GRACE" || return 1
    since=$(log_mark "EXIT then sleep") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "EXIT, then KEYCODE_SLEEP right away"
    adb_shell "am broadcast --include-stopped-packages -n $TARGET_PKG/$TARGET_RECEIVER -a $TARGET_ACTION.EXIT >/dev/null 2>&1; input keyevent KEYCODE_SLEEP" \
        >/dev/null 2>&1 || true
    expect_within 10 "the display did not turn off after KEYCODE_SLEEP" is_asleep || return 1
    if ! wait_for_log_ts 10 "$since" "$TARGET_TAG" "$(target_event_re EXIT "$TARGET_PKG")" >/dev/null; then
        fail "$NO_EXIT"
        return 1
    fi
    step "display off; waiting ${STAND_DOWN_S} s"
    sleep "$STAND_DOWN_S"
    if log_has "$since" WatchdogService "Relaunching"; then
        fail "the watchdog relaunched the target while the display was off"
        return 1
    fi
    if ! is_asleep; then
        fail "the display turned back on by itself (state: $(wakefulness))"
        return 1
    fi
    wake_since=$(log_mark "wake up") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "waking the device"
    wake_device
    expect_within 10 "the display did not wake up" is_awake || return 1
    expect_relaunch "$wake_since" "$TARGET_PKG" $((SCREEN_OFF_GRACE + BACK_TIMEOUT)) "back after wake" || return 1
    admin_cmd SET_GRACE --ei seconds "$FAST_GRACE" || return 1
    expect_pref grace_seconds "$FAST_GRACE" || return 1
}

scenario_set_target_validation() {
    local bogus=com.osamaalek.kiosklauncher.e2e.notinstalled out since exit_ts
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    step "admin SET_TARGET $bogus (not installed)"
    out=$(admin_broadcast SET_TARGET --es package "$bogus") || true
    detail "      $(one_line "$out")"
    if [[ "$(broadcast_result "$out")" != 1 ]]; then
        fail "SET_TARGET with a package that isn't installed: expected result=1, got: $(one_line "$out")"
        return 1
    fi
    note "rejected with $(one_line "${out##*Broadcast completed: }")"
    sleep 2
    expect_pref target_package "$TARGET_PKG" 5 || return 1
    since=$(log_mark "EXIT after the rejected SET_TARGET") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

scenario_admin_receiver_protected() {
    local since enabled lines exit_ts
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    since=$(log_mark "PROBE_ADMIN") || {
        fail "$NO_CLOCK"
        return 1
    }
    target_cmd PROBE_ADMIN || true
    if ! wait_for_log_ts 10 "$since" "$TARGET_TAG" "PROBE_ADMIN sent" >/dev/null; then
        fail "the test app did not log 'PROBE_ADMIN sent'"
        return 1
    fi
    step "giving the system 5 s to deliver it"
    sleep 5
    if log_has "$since" AdminCommandReceiver "$(re_escape "$LOADER_ACTION.DISABLE") applied"; then
        fail "the loader applied a DISABLE sent by an ordinary app: AdminCommandReceiver is not protected"
        return 1
    fi
    enabled=$(prefs_get enabled) || enabled=""
    if [[ $enabled == false ]]; then
        fail "the loader was disabled by an ordinary app"
        return 1
    fi
    lines=$(log_since "$since" ActivityManager BroadcastQueue) || lines=""
    if printf '%s\n' "$lines" | grep 'Permission Denial.*AdminCommandReceiver' >/dev/null; then
        note "the system logged a permission denial"
    else
        note "no permission denial logged (the broadcast may have been dropped earlier)"
    fi
    since=$(log_mark "EXIT after PROBE_ADMIN") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

scenario_vr_target() {
    local since
    ensure_launch_budget 2 || return 1
    require_target_foreground || return 1
    since=$(log_mark "SET_TARGET VR app") || {
        fail "$NO_CLOCK"
        return 1
    }
    if ! admin_try SET_TARGET --es package "$VR_TARGET_PKG"; then
        fail "SET_TARGET $VR_TARGET_PKG was rejected: the VR fallback (MAIN + com.oculus.intent.category.VR) did not find the app"
        return 1
    fi
    step "admin SET_TARGET $VR_TARGET_PKG: OK"
    expect_pref target_package "$VR_TARGET_PKG" || return 1
    expect_relaunch "$since" "$VR_TARGET_PKG" "$BACK_TIMEOUT" "VR target up" || return 1
    if ! log_has "$since" TargetLauncher "Launched $(re_escape "$VR_TARGET_PKG")\$"; then
        fail "TargetLauncher did not log 'Launched $VR_TARGET_PKG'"
        return 1
    fi
    since=$(log_mark "SET_TARGET back to the launcher test app") || {
        fail "$NO_CLOCK"
        return 1
    }
    admin_cmd SET_TARGET --es package "$TARGET_PKG" || return 1
    expect_pref target_package "$TARGET_PKG" || return 1
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" "launcher target back" || return 1
    force_stop "$VR_TARGET_PKG"
}

scenario_blind_mode() {
    local since exit_ts mode
    ensure_launch_budget 3 || return 1
    require_target_foreground || return 1
    step "appops set $LOADER_PKG GET_USAGE_STATS ignore"
    adb_shell appops set "$LOADER_PKG" GET_USAGE_STATS ignore >/dev/null 2>&1 || true
    mode=$(appops_mode "$LOADER_PKG" GET_USAGE_STATS)
    if [[ $mode != ignore ]]; then
        fail "could not take usage access away (GET_USAGE_STATS: ${mode:-unset})"
        return 1
    fi
    since=$(log_mark "EXIT without usage access") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BLIND_TIMEOUT" || return 1
    if ! log_has "$exit_ts" WatchdogService "Relaunching $(re_escape "$TARGET_PKG") \\(foreground: unknown\\)"; then
        fail "the relaunch did not come from the blind path (no 'foreground: unknown')"
        return 1
    fi
    step "appops set $LOADER_PKG GET_USAGE_STATS allow"
    if ! restore_usage_access; then
        fail "could not give usage access back"
        return 1
    fi
}

scenario_package_replaced() {
    local since old_pid out fg exit_ts
    # The relaunch below is the new service instance's; this is for bringing the target back first
    ensure_launch_budget 0 || return 1
    require_target_foreground || return 1
    old_pid=$(pid_of "$LOADER_PKG")
    since=$(log_mark "adb install -r loader") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "adb install -r $(rel_path "$LOADER_APK")"
    out=$(adb_ install -r "$LOADER_APK" 2>&1) || true
    detail "$out"
    if [[ $out != *Success* ]]; then
        fail "adb install -r of the loader failed: $(one_line "$out")"
        return 1
    fi
    expect_within 60 "WatchdogService did not come back after the update (MY_PACKAGE_REPLACED)" \
        watchdog_restarted "$old_pid" || return 1
    if ! wait_for_log_ts 10 "$since" WatchdogService "Watchdog started" >/dev/null; then
        fail "no 'Watchdog started' after the update"
        return 1
    fi
    fg=$(foreground_pkg)
    if [[ $fg == "$LOADER_PKG" ]]; then
        fail "the update opened the loader UI"
        return 1
    fi
    note "loader pid ${old_pid:-none} -> $(pid_of "$LOADER_PKG")"
    since=$(log_mark "EXIT after the update") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

scenario_reboot() {
    local since old_boot booted_at fg
    since=$(log_mark "reboot") || {
        fail "$NO_CLOCK"
        return 1
    }
    # The log buffer doesn't survive the reboot
    adb_ logcat -d -v threadtime >"$RESULTS_DIR/logcat-before-reboot.txt" 2>/dev/null || true
    old_boot=$(boot_id)
    step "adb reboot"
    if ! adb_ reboot >/dev/null 2>&1; then
        fail "adb reboot failed"
        return 1
    fi
    step "waiting for the device to go down"
    expect_within 120 "the device did not go down after adb reboot" old_boot_gone "$old_boot" || return 1
    step "waiting for the device to boot"
    expect_within 360 "the device did not finish booting" new_boot_ready "$old_boot" || return 1
    booted_at=$SECONDS
    prep_device || {
        fail "device preparation after the reboot failed"
        return 1
    }
    step "waiting for the target to start on its own"
    if ! wait_until $((REBOOT_TIMEOUT - (SECONDS - booted_at))) is_foreground "$TARGET_PKG"; then
        fg=$(foreground_pkg)
        fail "the target did not start within ${REBOOT_TIMEOUT} s of boot (foreground: ${fg:-none})"
        return 1
    fi
    note "target resumed $((SECONDS - booted_at)) s after boot completed"
    if ! log_has "$since" WatchdogService "Watchdog started"; then
        fail "no 'Watchdog started' after boot"
        return 1
    fi
    if ! watchdog_running; then
        fail "WatchdogService is not running as a foreground service after boot"
        return 1
    fi
    FRESH_WATCHDOG=yes
}

scenario_crash_loop_backoff() {
    local since crashes=0 pid throttled_re throttle_ts="" last_launch_ts rel_ts gap pkg_re
    pkg_re=$(re_escape "$TARGET_PKG")
    throttled_re="$pkg_re keeps exiting, relaunch throttled"
    # LaunchBackoff lives in the service instance: it needs one without earlier launches
    if [[ $FRESH_WATCHDOG != yes ]]; then
        step "restarting the loader, so the watchdog starts with an empty launch history"
        restart_watchdog || return 1
    fi
    FRESH_WATCHDOG=no
    require_target_foreground || return 1
    since=$(log_mark "crash loop") || {
        fail "$NO_CLOCK"
        return 1
    }
    while ((crashes < MAX_CRASHES)); do
        pid=$(pid_of "$TARGET_PKG")
        if [[ -z $pid ]]; then
            fail "the target has no process before crash $((crashes + 1))"
            return 1
        fi
        crashes=$((crashes + 1))
        target_cmd CRASH || true
        expect_within 15 "crash $crashes: process $pid is still alive" pid_not "$TARGET_PKG" "$pid" || return 1
        if ! wait_until 30 back_or_throttled "$since" "$pid"; then
            fail "after crash $crashes the target was neither relaunched nor throttled"
            return 1
        fi
        throttle_ts=$(log_first_ts "$since" WatchdogService "$throttled_re") || throttle_ts=""
        if [[ -n $throttle_ts ]]; then break; fi
    done
    if [[ -z $throttle_ts ]]; then
        fail "no 'relaunch throttled' after $crashes crashes"
        return 1
    fi
    step "throttled after $crashes crashes; waiting for the cooldown"
    expect_relaunch "$throttle_ts" "$TARGET_PKG" "$COOLDOWN_TIMEOUT" "back after the cooldown" || return 1
    last_launch_ts=$(log_grep "$since" TargetLauncher "Launched $pkg_re\$" |
        awk -v t="$throttle_ts" '($1 + 0) < (t + 0) { last = $1 } END { print last }') || last_launch_ts=""
    rel_ts=$(log_first_ts "$throttle_ts" WatchdogService "Relaunching $pkg_re \\(") || rel_ts=""
    if [[ -n $last_launch_ts && -n $rel_ts ]]; then
        gap=$(ts_diff "$rel_ts" "$last_launch_ts")
        if ts_lt "$gap" 55; then
            fail "relaunched ${gap} s after the previous launch, expected a cooldown of about 60 s"
            return 1
        fi
        note "throttled after $crashes crashes, next launch ${gap} s after the previous one"
    else
        note "throttled after $crashes crashes"
    fi
}

# ---------------------------------------------------------------------------------------------

main() {
    local selection line name i=0 failures
    parse_args "$@"
    if [[ $OPT_LIST == yes ]]; then
        list_scenarios
        return 0
    fi
    selection=$(select_scenarios "$OPT_ONLY" "$OPT_SKIP") || exit 2
    while IFS= read -r line; do
        if [[ -n $line ]]; then SELECTED+=("$line"); fi
    done <<<"$selection"

    LOADER_APK=$(abs_path "$OPT_LOADER_APK")
    TARGET_APK=$(abs_path "$OPT_TARGET_APK")
    VR_TARGET_APK=$(abs_path "$OPT_VR_TARGET_APK")
    RESULTS_DIR=$(abs_path "$OPT_RESULTS")
    mkdir -p "$RESULTS_DIR"
    clean_results
    RUN_LOG=$RESULTS_DIR/run.log
    : >"$RUN_LOG"
    RUN_TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%S')
    trap on_exit EXIT
    trap on_signal INT TERM

    log "Kiosk Launcher e2e: ${#SELECTED[@]} scenario(s): ${SELECTED[*]}"
    log "loader APK: $(rel_path "$LOADER_APK"); results: $(rel_path "$RESULTS_DIR")"
    check_apks
    find_adb
    pick_device
    check_device_kind
    DEVICE_SDK=$(device_prop ro.build.version.sdk)
    DEVICE_RELEASE=$(device_prop ro.build.version.release)
    DEVICE_MODEL=$(device_prop ro.product.model)
    log "device: $(device_title), $DEVICE_KIND"

    log "preparing the device"
    prep_device || abort_run "device $E2E_SERIAL did not finish booting"
    probe_device_clock
    probe_logcat || abort_run "can't read back the device log with 'logcat -v epoch'; the checks need it"
    log "setting up: removing the loader, installing the test apps"
    setup_device || abort_run "installing the test apps failed (see run.log)"

    for name in "${SELECTED[@]}"; do
        i=$((i + 1))
        if [[ -n $ABORT_REASON ]]; then
            record_result "$name" fail 0 "not run: $ABORT_REASON"
            continue
        fi
        if ! run_scenario "$name" "$i" "${#SELECTED[@]}" && [[ $name == provision ]]; then
            ABORT_REASON="provision failed"
        fi
    done

    finalize
    failures=$(count_failures)
    if ((failures > 0)); then
        log "$failures of ${#R_NAMES[@]} scenarios failed"
        exit 1
    fi
    log "all ${#R_NAMES[@]} scenarios passed"
    exit 0
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
