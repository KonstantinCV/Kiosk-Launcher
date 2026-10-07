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
    "provision|scripts/provision-quest.sh installs the loader, grants it (saved to disk), sets the target and starts the watchdog"
    "loader-ui-stands-down|nothing is launched while the loader UI is in front"
    "launches-target|leaving the loader UI (HOME) gets the target launched"
    "target-stays-put|a target that stays in front is left alone: nothing is relaunched for 25 s"
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
    "loader-crash|after the loader crashes, Android restarts the watchdog, which leaves the target alone until it exits"
    "reboot|after an unclean reboot the target starts with no interaction, and the provisioned state survived"
    "crash-loop-backoff|a crash loop gets throttled, and the target comes back after the cooldown"
)

# Timing. Emulators in CI render in software and are slow, so waits are generous.
BACK_TIMEOUT=${E2E_BACK_TIMEOUT:-30} # the target comes back after an exit (grace 3 s + 2 s ticks)
FAST_GRACE=3                         # grace period used by the scenarios, for speed
STAND_DOWN_S=12                      # how long "nothing happens" is watched
SCREEN_OFF_GRACE=6                   # see scenario_screen_off
GUARDIAN_WAIT_S=180                  # for a person to confirm a Quest's Guardian dialog
LONG_GRACE=12                        # see scenario_grace_period
LONG_GRACE_MAX=18                    # its relaunch: 12 s from the first tick after the exit, + slack
TICK_SETTLE_S=3                      # > one watchdog tick (2 s), see settle_target_front
STAY_PUT_S=25                        # see scenario_target_stays_put: over 8 grace periods
LOADER_RESTART_TIMEOUT=40            # see scenario_loader_crash
BLIND_TIMEOUT=55                     # grace + 30 s blind interval + margin
REBOOT_TIMEOUT=120                   # target resumed after boot completed
MAX_LAUNCHES=5      # LaunchBackoff: 5 launches in 3 minutes, then one per minute
COOLDOWN_TIMEOUT=80 # LaunchBackoff: one launch per 60 s once throttled
DEVICE_WAIT_S=30    # how long pick_device waits for a device that is still coming online
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
P_NAMES=() # report_rows: the rows of a report
P_RESULTS=()
P_SECS=()
P_NOTES=()
CURRENT_SCENARIO=""
CURRENT_START=0
SCENARIO_MARK=""
ABORT_REASON=""
FINALIZED=no
RUN_DONE=no # main got to the end; otherwise on_exit accounts for the scenarios left
PENDING_NOTE="not run: the run had not finished when this report was written (still running, or killed)"
CRASHED_PID="" # crash_target
CRASH_TS=""
LOADER_KILLED_BY="" # crash_loader
LOADER_KILL_TS=""
CRASH_RESULTS_LOST=0
WHITELIST_SET_AT=-100 # $SECONDS when the loader was last put in the deviceidle whitelist
WHITELIST_SAVE_S=6    # Android saves the whitelist 5 s after a change, and nothing forces it
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

Exit status: 0 if every selected scenario passed, 1 if one failed, 2 on usage or setup errors,
129, 130 or 143 when stopped by SIGHUP, SIGINT or SIGTERM.
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

# report_rows: sets P_NAMES, P_RESULTS, P_SECS and P_NOTES to the recorded results, then every
# selected scenario that has none yet, as not run: a report written while the run is going (or
# left behind by a run that was killed) never reads as a complete pass
report_rows() {
    local name
    P_NAMES=("${R_NAMES[@]+"${R_NAMES[@]}"}")
    P_RESULTS=("${R_RESULTS[@]+"${R_RESULTS[@]}"}")
    P_SECS=("${R_SECS[@]+"${R_SECS[@]}"}")
    P_NOTES=("${R_NOTES[@]+"${R_NOTES[@]}"}")
    for name in "${SELECTED[@]+"${SELECTED[@]}"}"; do
        if result_recorded "$name"; then continue; fi
        P_NAMES+=("$name")
        P_RESULTS+=(fail)
        P_SECS+=(0)
        P_NOTES+=("$PENDING_NOTE")
    done
}

# pending_count: selected scenarios without a result
pending_count() {
    local name n=0
    for name in "${SELECTED[@]+"${SELECTED[@]}"}"; do
        if ! result_recorded "$name"; then n=$((n + 1)); fi
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
    local file=$RESULTS_DIR/junit.xml n i failures=0 total=0 classname message body
    report_rows
    n=${#P_NAMES[@]}
    for ((i = 0; i < n; i++)); do
        total=$((total + P_SECS[i]))
        if [[ ${P_RESULTS[i]} != pass ]]; then failures=$((failures + 1)); fi
    done
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
            if [[ ${P_RESULTS[i]} == pass ]]; then
                printf '    <testcase classname="%s" name="%s" time="%d"/>\n' \
                    "$classname" "$(xml_escape "${P_NAMES[i]}")" "${P_SECS[i]}"
            else
                message=$(one_line "${P_NOTES[i]}")
                body="${P_NOTES[i]}"
                if [[ -e $RESULTS_DIR/logcat-${P_NAMES[i]}.txt ]]; then
                    body+=$'\n'"See logcat-${P_NAMES[i]}.txt, screenshot-${P_NAMES[i]}.png and dumpsys-${P_NAMES[i]}.txt in the results."
                fi
                printf '    <testcase classname="%s" name="%s" time="%d">\n' \
                    "$classname" "$(xml_escape "${P_NAMES[i]}")" "${P_SECS[i]}"
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
    local file=$RESULTS_DIR/summary.md n i failures=0 result pending
    pending=$(pending_count)
    report_rows
    n=${#P_NAMES[@]}
    for ((i = 0; i < n; i++)); do
        if [[ ${P_RESULTS[i]} != pass ]]; then failures=$((failures + 1)); fi
    done
    {
        printf '### Kiosk Launcher e2e: %s\n\n' "$(md_cell "$(device_title)")"
        if [[ -n $ABORT_REASON ]]; then
            printf '**Run stopped:** %s\n\n' "$(md_cell "$ABORT_REASON")"
        elif ((pending > 0)); then
            printf '**Run not finished:** %d scenario(s) had not run when this report was written (the run was still going, or was killed).\n\n' "$pending"
        fi
        printf '| Scenario | Result | Seconds | Note |\n'
        printf '| --- | --- | --- | --- |\n'
        for ((i = 0; i < n; i++)); do
            if [[ ${P_RESULTS[i]} == pass ]]; then result=pass; else result='**FAIL**'; fi
            printf '| %s | %s | %s | %s |\n' "${P_NAMES[i]}" "$result" "${P_SECS[i]}" "$(md_cell "${P_NOTES[i]}")"
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

# on_signal SIG: Ctrl-C, kill, or the terminal closing (HUP). The running scenario fails as
# interrupted, the ones after it as not run; the EXIT trap writes the reports.
on_signal() {
    local sig=$1 code
    case $sig in
    HUP) code=129 ;;
    TERM) code=143 ;;
    *) code=130 ;;
    esac
    trap - INT TERM HUP
    # Whatever reads our output may be gone with the terminal: keep going to write the reports
    trap '' PIPE
    log "interrupted (SIG$sig)"
    if [[ -n $CURRENT_SCENARIO ]] && ! result_recorded "$CURRENT_SCENARIO"; then
        record_result "$CURRENT_SCENARIO" fail $((SECONDS - CURRENT_START)) "interrupted (SIG$sig)"
    fi
    CURRENT_SCENARIO=""
    ABORT_REASON="interrupted (SIG$sig)"
    record_not_run "$ABORT_REASON"
    exit "$code"
}

# on_exit: the EXIT trap. If main didn't get to the end (an unexpected error), the scenarios left
# are accounted for too, and the exit status is never 0.
on_exit() {
    local rc=$?
    if [[ $RUN_DONE != yes ]]; then
        if [[ -n $CURRENT_SCENARIO ]] && ! result_recorded "$CURRENT_SCENARIO"; then
            record_result "$CURRENT_SCENARIO" fail $((SECONDS - CURRENT_START)) \
                "the run stopped in this scenario (exit status $rc)"
        fi
        CURRENT_SCENARIO=""
        if (($(pending_count) > 0)); then
            ABORT_REASON=${ABORT_REASON:-"the run stopped unexpectedly (exit status $rc)"}
            record_not_run "$ABORT_REASON"
            FINALIZED=no
        fi
    fi
    finalize || true
    if [[ $RUN_DONE != yes ]] && ((rc == 0)); then exit 1; fi
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

# find_adb: the SDK's adb ($ANDROID_HOME, then $ANDROID_SDK_ROOT), else the one on PATH, the same
# choice as e2e/start-emulator.sh: two different adb versions keep restarting each other's server
find_adb() {
    local sdk found=""
    for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}"; do
        if [[ -n $sdk && -x $sdk/platform-tools/adb ]]; then
            found=$sdk/platform-tools/adb
            break
        fi
    done
    if [[ -z $found ]]; then found=$(command -v adb 2>/dev/null) || found=""; fi
    if [[ -z $found ]]; then
        abort_run "adb not found: set ANDROID_HOME to the Android SDK, or put its platform-tools on PATH"
    fi
    ADB=$found
    # scripts/provision-quest.sh runs plain `adb`: make sure it is this one
    PATH="$(dirname "$ADB"):$PATH"
    export PATH
}

# state_hints "SERIAL (STATE), ...": what to do about devices adb lists but can't use
state_hints() {
    local hints=""
    if [[ $1 == *unauthorized* ]]; then
        hints+=" unauthorized: accept the 'Allow USB debugging' prompt on the device (put the headset on)."
    fi
    if [[ $1 == *offline* ]]; then
        hints+=" offline: an emulator that is still booting, or a device adb lost (reconnect it, or run 'adb reconnect offline')."
    fi
    if [[ $1 == *"no permissions"* ]]; then
        hints+=" no permissions: the host's udev rules don't let this user open the USB device."
    fi
    printf '%s\n' "${hints:- Check the device, or restart it.}"
}

# pick_device: --serial, $ANDROID_SERIAL or the only device in state "device". A device adb lists
# in another state (offline while an emulator boots, unauthorized until the prompt is accepted)
# gets up to DEVICE_WAIT_S seconds; with nothing listed at all it fails right away.
pick_device() {
    local serial=${OPT_SERIAL:-${ANDROID_SERIAL:-}} out list online others count state waited=no deadline
    deadline=$((SECONDS + DEVICE_WAIT_S))
    if [[ -n $serial ]]; then
        while true; do
            state=$("$ADB" -s "$serial" get-state 2>&1 </dev/null) || true
            state=$(one_line "$(printf '%s' "$state" | tr -d '\r')")
            if [[ $state == device ]]; then break; fi
            if ((SECONDS >= deadline)); then
                abort_run "device $serial is not available after ${DEVICE_WAIT_S} s (adb get-state: ${state:-no answer}).$(state_hints "$state")"
            fi
            if [[ $waited == no ]]; then
                log "device $serial is not ready (adb get-state: ${state:-no answer}), waiting up to ${DEVICE_WAIT_S} s"
                waited=yes
            fi
            sleep 1
        done
        E2E_SERIAL=$serial
        return 0
    fi
    while true; do
        out=$("$ADB" devices 2>&1 </dev/null) || abort_run "'$ADB devices' failed: $(one_line "$out")"
        # "serial<TAB>state" lines; adb's own messages ("* daemon started ...") have no tab
        list=$(printf '%s\n' "$out" | tr -d '\r' | awk -F '\t' 'NF >= 2 && $1 != "" { print $1 "\t" $2 }')
        online=$(printf '%s\n' "$list" | awk -F '\t' '$2 == "device" { print $1 }')
        count=$(printf '%s\n' "$online" | awk 'NF { n++ } END { print n + 0 }')
        if ((count > 0)); then break; fi
        others=$(printf '%s\n' "$list" | awk -F '\t' 'NF >= 2 { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')
        if [[ -z $others ]]; then
            abort_run "no device attached. Start an emulator (e2e/start-emulator.sh), or connect a headset and pass --allow-real-device"
        fi
        if ((SECONDS >= deadline)); then
            abort_run "no usable device after ${DEVICE_WAIT_S} s: $others.$(state_hints "$others")"
        fi
        if [[ $waited == no ]]; then
            log "no device ready yet ($others), waiting up to ${DEVICE_WAIT_S} s"
            waited=yes
        fi
        sleep 1
    done
    if ((count > 1)); then
        abort_run "several devices attached ($(printf '%s' "$online" | tr '\n' ' ')): pick one with --serial or ANDROID_SERIAL"
    fi
    E2E_SERIAL=$online
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
    wait_guardian_closed "$GUARDIAN_WAIT_S" || step "the Guardian dialog is still open"
    if ! package_installed "$LOADER_PKG"; then
        adb_ install -r -g "$LOADER_APK" >>"$RUN_LOG" 2>&1 || true
        adb_shell dumpsys deviceidle whitelist "+$LOADER_PKG" >/dev/null 2>&1 || true
        WHITELIST_SET_AT=$SECONDS
    fi
    # Saved right away, so a later reboot keeps the provisioned grants
    appops_cmd set "$LOADER_PKG" SYSTEM_ALERT_WINDOW allow || true
    appops_cmd set "$LOADER_PKG" GET_USAGE_STATS allow || true
    appops_save || true
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
        # A 2D app left resumed beside the Horizon OS home isn't relaunched; bring it to front
        if has_pid "$TARGET_PKG" && bring_target_front; then return 0; fi
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
    E2E_FAIL_PREFIX=""
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
    E2E_FAIL_PREFIX=""
    secs=$((SECONDS - CURRENT_START))
    # Recorded before CURRENT_SCENARIO is cleared: a signal in between must not lose the result
    if [[ $ok == yes ]]; then
        record_result "$name" pass "$secs" "$E2E_NOTE"
        CURRENT_SCENARIO=""
        log "PASS $name (${secs} s)"
    else
        if [[ -z $E2E_FAIL_REASON ]]; then E2E_FAIL_REASON="the scenario returned an error"; fi
        record_result "$name" fail "$secs" "$E2E_FAIL_REASON"
        CURRENT_SCENARIO=""
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
    if ! wait_guardian_closed "$GUARDIAN_WAIT_S"; then
        fail "precondition: Horizon OS's Guardian dialog is open: confirm the boundary in the headset"
        return 1
    fi
    fg=$(foreground_pkg)
    if [[ $fg == "$TARGET_PKG" ]] && wait_until 10 has_pid "$TARGET_PKG"; then return 0; fi
    if [[ $fg != "$LOADER_PKG" ]] && has_pid "$TARGET_PKG"; then
        # Running but not in front: on Horizon OS a 2D app stays resumed as a panel beside the
        # home, and the watchdog rightly leaves it alone
        step "the target is running but not in front (foreground: ${fg:-none}), bringing it to front"
        if bring_target_front; then return 0; fi
    fi
    step "the target is not in front (foreground: ${fg:-none}), waiting for the watchdog"
    if [[ $fg == "$LOADER_PKG" ]]; then press_key KEYCODE_HOME; fi
    if wait_until 60 in_front_and_running "$TARGET_PKG"; then return 0; fi
    fg=$(foreground_pkg)
    fail "precondition: the target app is not in the foreground (foreground: ${fg:-none})"
}

# settle_target_front: lets a watchdog tick (every 2 s) see the target in front before the
# scenario makes it leave. WatchdogPolicy starts the grace period when it launches the target and
# starts it over only once a tick sees the target in front, so an EXIT right after the watchdog's
# own launch is relaunched on the launch's clock: early, and not because of the exit.
settle_target_front() {
    local pid
    wait_until 10 has_pid "$TARGET_PKG" || true
    pid=$(pid_of "$TARGET_PKG")
    step "letting a watchdog tick see the target in front (${TICK_SETTLE_S} s)"
    sleep "$TICK_SETTLE_S"
    if ! is_foreground "$TARGET_PKG" || [[ -z $pid || "$(pid_of "$TARGET_PKG")" != "$pid" ]]; then
        fail "precondition: the target did not stay in front for ${TICK_SETTLE_S} s (foreground: $(foreground_pkg), pid ${pid:-none} -> $(pid_of "$TARGET_PKG"))"
        return 1
    fi
}

# exit_target SINCE: sends EXIT, prints when the test app logged it
exit_target() {
    target_cmd EXIT || true
    wait_for_log_ts 10 "$1" "$TARGET_TAG" "$(target_event_re EXIT "$TARGET_PKG")"
}

# grant_problems: the loader's app ops that aren't allow, e.g. "GET_USAGE_STATS is 'ignore'";
# nothing if both are
grant_problems() {
    local op mode sep=""
    for op in SYSTEM_ALERT_WINDOW GET_USAGE_STATS; do
        mode=$(appops_mode "$LOADER_PKG" "$op")
        if [[ $mode != allow ]]; then
            printf "%s%s is '%s'" "$sep" "$op" "${mode:-unset}"
            sep="; "
        fi
    done
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

# restore_usage_access: GET_USAGE_STATS back to allow, saved, and read back from disk
restore_usage_access() {
    appops_set_saved "$LOADER_PKG" GET_USAGE_STATS allow || return 1
    appops_reload || return 1
    [[ "$(appops_mode "$LOADER_PKG" GET_USAGE_STATS)" == allow ]]
}

# crash_target N LAUNCH_TS: crash N of crash-loop-backoff. The target must be resumed, in the
# process that logged RESUMED after LAUNCH_TS; then CRASH must be taken by the test app and logged
# by exactly that process, and the process must die. Sets CRASHED_PID and CRASH_TS.
crash_target() {
    local n=$1 launch_ts=$2 pid mark result data pkg_re
    pkg_re=$(re_escape "$TARGET_PKG")
    CRASHED_PID=""
    CRASH_TS=""
    E2E_FAIL_PREFIX="crash $n: "
    if ! is_foreground "$TARGET_PKG"; then
        fail "the target is not in front before the crash (foreground: $(foreground_pkg))"
        return 1
    fi
    pid=$(pid_of "$TARGET_PKG")
    if [[ -z $pid ]]; then
        fail "the target has no process"
        return 1
    fi
    if ! wait_until 10 log_has "$launch_ts" "$TARGET_TAG" "RESUMED pkg=$pkg_re pid=$pid\$"; then
        fail "process $pid of the target did not log RESUMED after launch $n"
        return 1
    fi
    mark=$(log_mark "crash $n, pid $pid") || {
        fail "$NO_CLOCK"
        return 1
    }
    target_cmd CRASH || true
    CRASH_TS=$(wait_for_log_ts 10 "$mark" "$TARGET_TAG" "CRASH pkg=$pkg_re pid=$pid\$") || {
        CRASH_TS=""
        fail "process $pid did not log 'CRASH pkg=$TARGET_PKG pid=$pid' (am broadcast: $(one_line "$TARGET_CMD_OUT"))"
        return 1
    }
    result=$(broadcast_result "$TARGET_CMD_OUT")
    data=$(broadcast_data "$TARGET_CMD_OUT")
    if [[ $result == -1 && $data == OK ]]; then
        :
    elif [[ $result == 0 && -z $data ]]; then
        # The result goes to the system in a one-way call that the crash can overtake (the test
        # app throws a moment after onReceive for that reason; before, CI saw it on both API
        # levels): am then prints result=0. The CRASH line above shows this process did take the
        # command, so this is not a lost command. Noted in the summary.
        CRASH_RESULTS_LOST=$((CRASH_RESULTS_LOST + 1))
        step "am printed result=0: the process died before its result got through (it logged CRASH, so it got the command)"
    else
        fail "the test app did not take CRASH (expected result=-1, data=\"OK\"): $(one_line "$TARGET_CMD_OUT")"
        return 1
    fi
    expect_within 15 "process $pid is still alive after CRASH" pid_not "$TARGET_PKG" "$pid" || return 1
    CRASHED_PID=$pid
}

# crash_loader PID SINCE: crashes the loader's process PID with `am crash` (an uncaught exception
# on its main thread, as a bug in the loader would throw), right after the log mark SINCE. If the
# device refuses that, or it doesn't kill the process within 10 s, kills it with
# `run-as <loader> kill -9` instead (the debug build is debuggable). Waits for PID to be gone; sets
# LOADER_KILLED_BY to what did it, and LOADER_KILL_TS to a device time just before that.
crash_loader() {
    local pid=$1 out rc=0 refused=no why
    LOADER_KILLED_BY=""
    LOADER_KILL_TS=$2
    step "am crash $LOADER_PKG (pid $pid)"
    out=$(adb_shell am crash "$LOADER_PKG" 2>&1) || rc=$?
    detail "      am crash: $(one_line "${out:-<no output>}") (exit $rc)"
    if ((rc != 0)) || [[ $out == *"Unknown command"* || $out == *Exception* ]]; then refused=yes; fi
    if [[ $refused == no ]]; then wait_until 10 pid_not "$LOADER_PKG" "$pid" || true; fi
    if pid_not "$LOADER_PKG" "$pid"; then
        LOADER_KILLED_BY="am crash"
        return 0
    fi
    if [[ $refused == yes ]]; then
        why="am crash was refused: $(one_line "${out:-exit $rc}")"
    else
        why="am crash left it running for 10 s"
    fi
    step "$why; run-as $LOADER_PKG kill -9 $pid"
    LOADER_KILL_TS=$(log_mark "run-as kill -9 $pid") || {
        fail "$NO_CLOCK"
        return 1
    }
    rc=0
    out=$(adb_shell run-as "$LOADER_PKG" kill -9 "$pid" 2>&1) || rc=$?
    detail "      run-as kill -9: $(one_line "${out:-<no output>}") (exit $rc)"
    if wait_until 10 pid_not "$LOADER_PKG" "$pid"; then
        LOADER_KILLED_BY="run-as kill -9 ($why)"
        return 0
    fi
    fail "the loader (pid $pid) is still alive: $why, and run-as kill -9 did not kill it either: $(one_line "${out:-exit $rc}")"
}

# ---------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------

scenario_provision() {
    local rc=0 log_file=$RESULTS_DIR/provision.log problems
    step "scripts/provision-quest.sh $(rel_path "$LOADER_APK") $TARGET_PKG $E2E_SERIAL"
    bash "$REPO_ROOT/scripts/provision-quest.sh" "$LOADER_APK" "$TARGET_PKG" "$E2E_SERIAL" \
        >"$log_file" 2>&1 </dev/null || rc=$?
    WHITELIST_SET_AT=$SECONDS # it adds the loader to the deviceidle whitelist
    sed 's/^/      | /' "$log_file" >>"$RUN_LOG" 2>/dev/null || true
    if ((rc != 0)); then
        fail "provision-quest.sh exited with $rc: $(one_line "$(tail -n 3 "$log_file")")"
        return 1
    fi
    problems=$(grant_problems)
    if [[ -n $problems ]]; then
        fail "after provision-quest.sh, appops of the loader: $problems (expected allow)"
        return 1
    fi
    # Granted is not enough: Android saves app ops to disk about 10 s after a change, and a power
    # cut or adb reboot before that brings back the old ones. read-settings replaces the state in
    # memory with the saved one, so what is checked below is what a reboot keeps.
    step "appops read-settings: reloading the saved app ops, as after a reboot"
    if ! appops_reload; then
        fail "'adb shell appops read-settings' failed or is not supported on this device: $(one_line "${APPOPS_OUT:-no output}"). The suite needs it to check that the grants are saved"
        return 1
    fi
    problems=$(grant_problems)
    if [[ -n $problems ]]; then
        fail "reloaded from disk, appops of the loader: $problems (expected allow): the grant was only in memory, so a reboot or power cut soon after provisioning would lose it (provision-quest.sh must save it with 'appops write-settings')"
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
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" "launched" any || return 1
    if ! log_has "$since" TargetLauncher "Launched $pkg_re\$"; then
        fail "TargetLauncher did not log 'Launched $TARGET_PKG'"
        return 1
    fi
    if ! log_has "$since" "$TARGET_TAG" "$(target_event_re CREATED "$TARGET_PKG")"; then
        fail "the test app did not log CREATED"
        return 1
    fi
}

# A target in front must be left alone. Launching it again would not show as a new process or as
# a usage event: Android just hands the launch intent to the activity already on top (pausing and
# resuming a singleTask app such as the test app or a Unity app for it). So a watchdog that lost
# track of a target in front would relaunch it every grace period, for as long as it stays there.
scenario_target_stays_put() {
    local since pid fg now_pid relaunches
    ensure_launch_budget 0 || return 1
    require_target_foreground || return 1
    settle_target_front || return 1
    pid=$(pid_of "$TARGET_PKG")
    since=$(log_mark "target in front, pid $pid") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "waiting ${STAY_PUT_S} s with the target in front (grace period ${FAST_GRACE} s)"
    sleep "$STAY_PUT_S"
    relaunches=$(log_grep "$since" WatchdogService "Relaunching") || relaunches=""
    if [[ -n $relaunches ]]; then
        fail "the watchdog relaunched the target $(printf '%s\n' "$relaunches" | awk 'END { print NR }') time(s) in ${STAY_PUT_S} s although it stayed in front (the first logged foreground: $(printf '%s\n' "$relaunches" | parse_relaunch_foreground))"
        return 1
    fi
    fg=$(foreground_pkg)
    now_pid=$(pid_of "$TARGET_PKG")
    if [[ $fg != "$TARGET_PKG" || $now_pid != "$pid" ]]; then
        fail "the target did not stay in front for ${STAY_PUT_S} s (foreground: ${fg:-none}, pid $pid -> ${now_pid:-none})"
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
    if ! wait_until 5 log_has "$since" "$TARGET_TAG" "$(target_event_re PAUSED "$TARGET_PKG")" &&
        has_pid "$TARGET_PKG"; then
        # Horizon OS keeps a 2D app resumed as a panel beside the home: it never left, so there is
        # nothing to relaunch. The watchdog must leave it alone, as it does any target in front.
        expect_stays_away "$since" "$STAND_DOWN_S" "while it stayed resumed as a panel beside the home" || return 1
        note "the target stayed resumed as a panel beside the home (Horizon OS), so nothing was relaunched"
        bring_target_front || true
        return 0
    fi
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

# After the exit, the first tick (within 2 s) starts the grace period and a tick 12 s later
# relaunches: 12 to 14 s after the exit, 16 s if that first tick missed the exit. The settle
# before the exit makes the grace period start from the exit, not from the watchdog's last launch.
scenario_grace_period() {
    local since exit_ts delay
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    admin_cmd SET_GRACE --ei seconds "$LONG_GRACE" || return 1
    expect_pref grace_seconds "$LONG_GRACE" || return 1
    settle_target_front || return 1
    since=$(log_mark "EXIT with a $LONG_GRACE s grace period") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_stays_away "$exit_ts" 6 "within 6 s of the exit with a $LONG_GRACE s grace period" || return 1
    expect_relaunch "$exit_ts" "$TARGET_PKG" $((LONG_GRACE + BACK_TIMEOUT)) || return 1
    if [[ -n $RELAUNCH_TS ]]; then
        delay=$(ts_diff "$RELAUNCH_TS" "$exit_ts")
        if ts_lt "$delay" 11.5; then
            fail "relaunched ${delay} s after the exit, before the $LONG_GRACE s grace period was over"
            return 1
        fi
        if ts_lt "$LONG_GRACE_MAX" "$delay"; then
            fail "relaunched ${delay} s after the exit: with a $LONG_GRACE s grace period and 2 s ticks it should take at most about $LONG_GRACE_MAX s"
            return 1
        fi
    fi
    admin_cmd SET_GRACE --ei seconds "$FAST_GRACE" || return 1
    expect_pref grace_seconds "$FAST_GRACE" || return 1
}

# PAUSE, like DISABLE below, stops the grace period on the next tick, so an EXIT right after the
# watchdog's own launch needs no settle here
scenario_pause_resume() {
    local since exit_ts
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
    if [[ -n $RELAUNCH_TS ]] && ! ts_lt "$(ts_diff "$RELAUNCH_TS" "$since")" 55; then
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
# before the display is off would be a test race, not a loader bug; so is one counted from the
# watchdog's own launch just before (hence the settle). 12 s asleep is still twice the grace
# period, so a watchdog that ignored the display state would be caught.
scenario_screen_off() {
    local since wake_since
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    admin_cmd SET_GRACE --ei seconds "$SCREEN_OFF_GRACE" || return 1
    expect_pref grace_seconds "$SCREEN_OFF_GRACE" || return 1
    settle_target_front || return 1
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
    # A Quest may show its Guardian dialog on wake; the watchdog must wait for it, not use up its
    # launch budget on launches the dialog holds up
    if wait_until 5 guardian_in_front; then
        if ! wait_guardian_closed "$GUARDIAN_WAIT_S"; then
            fail "Horizon OS's Guardian dialog stayed open for ${GUARDIAN_WAIT_S} s after wake: confirm the boundary in the headset"
            return 1
        fi
        note "Guardian dialog after wake, closed $(ts_diff "$(device_epoch)" "$wake_since") s after wake"
    fi
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

# The test app sends the loader's AdminCommandReceiver an ordered DISABLE with result code 42 and
# data "untouched", and logs how it ended: the loader's receiver would have set -1/"OK", and
# 42/"untouched" means no receiver ran. The ENABLE from the adb shell first shows the receiver is
# reachable, so a probe that never got anywhere can't pass for a protected receiver. API 29 also
# logs a permission denial; API 34 logs nothing.
scenario_admin_receiver_protected() {
    local since enabled lines exit_ts out result
    ensure_launch_budget 1 || return 1
    require_target_foreground || return 1
    step "control: ENABLE from the adb shell (holds WRITE_SECURE_SETTINGS) must reach the receiver"
    out=$(admin_broadcast ENABLE) || true
    detail "      $(one_line "$out")"
    if ! broadcast_ok "$out"; then
        fail "control: ENABLE from the adb shell did not reach AdminCommandReceiver (expected result=-1, data=\"OK\"): $(one_line "$out")"
        return 1
    fi
    since=$(log_mark "PROBE_ADMIN") || {
        fail "$NO_CLOCK"
        return 1
    }
    target_cmd PROBE_ADMIN || true
    if ! wait_for_log_ts 10 "$since" "$TARGET_TAG" "PROBE_ADMIN sent" >/dev/null; then
        fail "the test app did not log 'PROBE_ADMIN sent' (am broadcast: $(one_line "$TARGET_CMD_OUT"))"
        return 1
    fi
    if ! wait_for_log_ts 15 "$since" "$TARGET_TAG" "PROBE_ADMIN result=" >/dev/null; then
        fail "the test app did not log 'PROBE_ADMIN result=...': its ordered broadcast to the loader never completed"
        return 1
    fi
    result=$(log_grep "$since" "$TARGET_TAG" "PROBE_ADMIN result=" | parse_probe_result) || result=""
    if [[ -z $result ]]; then
        fail "can't read the probe's result from: $(one_line "$(log_grep "$since" "$TARGET_TAG" "PROBE_ADMIN result=")")"
        return 1
    fi
    step "probe ended with result=${result% *} data=${result#* }"
    if [[ $result == "-1 OK" ]]; then
        fail "AdminCommandReceiver handled a DISABLE sent by an ordinary app (result=-1 data=OK): it is not protected"
        return 1
    fi
    if [[ $result != "42 untouched" ]]; then
        fail "PROBE_ADMIN ended with result=${result% *} data=${result#* }, expected result=42 data=untouched (no receiver ran)"
        return 1
    fi
    if log_has "$since" AdminCommandReceiver "$(re_escape "$LOADER_ACTION.DISABLE") applied"; then
        fail "the loader applied a DISABLE sent by an ordinary app: AdminCommandReceiver is not protected"
        return 1
    fi
    enabled=$(prefs_get enabled) || enabled=""
    if [[ $enabled != true ]]; then
        fail "the loader setting enabled is '${enabled:-unreadable}' after the probe, expected true"
        return 1
    fi
    note "probe result=42 data=untouched (dropped)"
    lines=$(log_since "$since" ActivityManager BroadcastQueue) || lines=""
    if printf '%s\n' "$lines" | grep 'Permission Denial.*AdminCommandReceiver' >/dev/null; then
        note "the system logged a permission denial"
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
    expect_relaunch "$since" "$VR_TARGET_PKG" "$BACK_TIMEOUT" "VR target up" any || return 1
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
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" "launcher target back" any || return 1
    force_stop "$VR_TARGET_PKG"
}

# Every app-op change is saved right away (appops write-settings): what is on disk stays what
# was provisioned, which is what the reboot scenario checks survives
scenario_blind_mode() {
    local since exit_ts mode
    ensure_launch_budget 3 || return 1
    require_target_foreground || return 1
    step "appops set $LOADER_PKG GET_USAGE_STATS ignore (saved)"
    appops_set_saved "$LOADER_PKG" GET_USAGE_STATS ignore || true
    mode=$(appops_mode "$LOADER_PKG" GET_USAGE_STATS)
    if [[ $mode != ignore ]]; then
        fail "could not take usage access away (GET_USAGE_STATS: ${mode:-unset}; appops: $(one_line "${APPOPS_OUT:-no output}"))"
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
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BLIND_TIMEOUT" relaunched unknown || return 1
    step "appops set $LOADER_PKG GET_USAGE_STATS allow (saved, then read back from disk)"
    if ! restore_usage_access; then
        fail "could not give usage access back and save it (GET_USAGE_STATS: $(appops_mode "$LOADER_PKG" GET_USAGE_STATS); appops: $(one_line "${APPOPS_OUT:-no output}"))"
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

# The loader crashes while the target is in front, and nobody opens its UI: only Android can bring
# the watchdog back. WatchdogService is a sticky foreground service, so Android restarts it in a new
# process, normally about 1 s after the crash (recent versions, 14 among them, wait 10 to 30 s
# longer under memory pressure, hence LOADER_RESTART_TIMEOUT). The new instance starts from
# nothing: a new foreground tracker, grace period and launch backoff. It must see that the target
# is already in front and leave it alone, and still relaunch it after an exit. The loader is
# crashed only once per run: after a second crash within a minute or two, Android waits 30 minutes
# before restarting the service.
scenario_loader_crash() {
    local since old_pid new_pid target_pid start_ts fg now_pid relaunches exit_ts
    # The relaunch below is the new service instance's; this is for bringing the target back first
    ensure_launch_budget 0 || return 1
    require_target_foreground || return 1
    settle_target_front || return 1
    target_pid=$(pid_of "$TARGET_PKG")
    old_pid=$(pid_of "$LOADER_PKG")
    if [[ -z $old_pid ]] || ! watchdog_running; then
        fail "precondition: WatchdogService is not running (loader pid: ${old_pid:-none})"
        return 1
    fi
    since=$(log_mark "crashing the loader, pid $old_pid") || {
        fail "$NO_CLOCK"
        return 1
    }
    crash_loader "$old_pid" "$since" || return 1
    note "loader killed by $LOADER_KILLED_BY"
    step "waiting for Android to restart WatchdogService by itself"
    expect_within "$LOADER_RESTART_TIMEOUT" "WatchdogService did not come back after the loader process died: Android did not restart the sticky service" \
        watchdog_restarted "$old_pid" || return 1
    new_pid=$(pid_of "$LOADER_PKG")
    start_ts=$(wait_for_log_ts 10 "$since" WatchdogService "Watchdog started") || {
        fail "WatchdogService runs again (pid ${new_pid:-none}) but logged no 'Watchdog started'"
        return 1
    }
    if ! log_grep "$since" WatchdogService "Watchdog started" | awk -v p="$new_pid" '$2 == p { f = 1 } END { exit !f }'; then
        fail "'Watchdog started' was not logged by the new loader process $new_pid: $(one_line "$(log_grep "$since" WatchdogService "Watchdog started")")"
        return 1
    fi
    note "loader pid $old_pid -> $new_pid, watchdog back $(ts_diff "$start_ts" "$LOADER_KILL_TS") s after the crash"
    fg=$(foreground_pkg)
    if [[ $fg == "$LOADER_PKG" ]]; then
        fail "the loader UI opened after the crash"
        return 1
    fi
    step "checking that the new watchdog leaves the target alone for ${STAND_DOWN_S} s (grace period ${FAST_GRACE} s)"
    sleep "$STAND_DOWN_S"
    relaunches=$(log_grep "$since" WatchdogService "Relaunching") || relaunches=""
    if [[ -n $relaunches ]]; then
        fail "the restarted watchdog relaunched the target although it stayed in front (it logged foreground: $(printf '%s\n' "$relaunches" | parse_relaunch_foreground))"
        return 1
    fi
    fg=$(foreground_pkg)
    now_pid=$(pid_of "$TARGET_PKG")
    if [[ $fg != "$TARGET_PKG" || $now_pid != "$target_pid" ]]; then
        fail "the target did not stay in front through the loader crash (foreground: ${fg:-none}, pid $target_pid -> ${now_pid:-none})"
        return 1
    fi
    since=$(log_mark "EXIT after the loader crash") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" || return 1
}

# `adb reboot` is the harsh path: no clean framework shutdown, like a power cut, so whatever
# Android had not saved yet is lost. After boot the target must start with no interaction, the
# provisioned state must still be there, and the watchdog must work with it: an EXIT is relaunched
# with the foreground known (without usage access it would only relaunch blind, every 30 s).
scenario_reboot() {
    local since old_boot booted_at fg boot_fg exit_ts problems target wait_s lost=()
    # The app ops are saved on demand (appops write-settings); the deviceidle whitelist only 5 s
    # after a change. Right after provisioning (--only reboot), give Android that time: a
    # whitelist lost to an early power cut is Android's behavior, not what this checks.
    wait_s=$((WHITELIST_SET_AT + WHITELIST_SAVE_S - SECONDS))
    if ((wait_s > 0)); then
        step "waiting ${wait_s} s: Android saves the deviceidle whitelist 5 s after a change"
        sleep "$wait_s"
    fi
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
    # The first launch after boot may not know the foreground yet: noted, not checked
    boot_fg=$(log_grep "$since" WatchdogService "Relaunching $(re_escape "$TARGET_PKG") \\(" | parse_relaunch_foreground) ||
        boot_fg=""
    if [[ -n $boot_fg ]]; then note "boot launch logged foreground: $boot_fg"; fi
    step "checking that the provisioned state survived the reboot"
    problems=$(grant_problems)
    if [[ -n $problems ]]; then
        lost+=("appops of the loader: $problems (expected allow): not saved before the reboot")
    fi
    if ! in_deviceidle_whitelist "$LOADER_PKG"; then
        lost+=("the loader is no longer in the deviceidle whitelist")
    fi
    target=$(prefs_get target_package) || target="<unreadable>"
    if [[ $target != "$TARGET_PKG" ]]; then
        lost+=("loader setting target_package is '$target', expected '$TARGET_PKG'")
    fi
    if ((${#lost[@]} > 0)); then
        fail "after the reboot: $(printf '%s; ' "${lost[@]}" | sed 's/; $//')"
        return 1
    fi
    settle_target_front || return 1
    since=$(log_mark "EXIT after the reboot") || {
        fail "$NO_CLOCK"
        return 1
    }
    exit_ts=$(exit_target "$since") || {
        fail "$NO_EXIT"
        return 1
    }
    expect_relaunch "$exit_ts" "$TARGET_PKG" "$BACK_TIMEOUT" "relaunched after the reboot" || return 1
}

# LaunchBackoff lives in the service instance, so the loader is restarted first (whatever ran
# before) and launch 1 comes from HOME. Then every crash must be a real one (taken and logged by
# the process that was in front, which then dies) and must be followed by exactly one launch,
# until the 5th launch in 3 minutes: its crash is throttled, and the next launch comes about 60 s
# after launch 5. Timings are from the device log. crash_loop_verdict re-checks the whole log.
scenario_crash_loop_backoff() {
    local start verdict lines
    CRASH_RESULTS_LOST=0
    start=$(log_mark "crash loop: restarting the loader") || {
        fail "$NO_CLOCK"
        return 1
    }
    step "restarting the loader, so the watchdog starts with an empty launch history"
    restart_watchdog ui || return 1
    if ! wait_for_log_ts 10 "$start" WatchdogService "Watchdog started" >/dev/null; then
        fail "no 'Watchdog started' after restarting the loader"
        return 1
    fi
    if ! crash_loop_steps; then
        # Say what the log shows went wrong, if it is more than the step that failed
        E2E_FAIL_PREFIX=""
        lines=$(log_since "$start" WatchdogService "$TARGET_TAG") || lines=""
        verdict=$(printf '%s\n' "$lines" | crash_loop_verdict "$TARGET_PKG") || true
        if [[ $verdict == "fail "* ]]; then E2E_FAIL_REASON+=" (in the log: ${verdict#fail })"; fi
        return 1
    fi
    E2E_FAIL_PREFIX=""
    lines=$(log_since "$start" WatchdogService "$TARGET_TAG") || lines=""
    if ! verdict=$(printf '%s\n' "$lines" | crash_loop_verdict "$TARGET_PKG"); then
        fail "crash loop log: ${verdict#* }"
        return 1
    fi
    note "${verdict#ok }"
    if ((CRASH_RESULTS_LOST > 0)); then
        note "am printed result=0 for $CRASH_RESULTS_LOST CRASH command(s): the process died before its result got through; each crash is confirmed by its pid's CRASH line"
    fi
}

# crash_loop_steps: launch 1 from HOME, then crash, launch, ..., crash 5, throttle, the launch
# after the cooldown, checked one step at a time as they happen
crash_loop_steps() {
    local since n new_pid throttle_ts after pkg_re throttled_re
    pkg_re=$(re_escape "$TARGET_PKG")
    throttled_re="$pkg_re keeps exiting, relaunch throttled"
    since=$(log_mark "crash loop: HOME, launch 1") || {
        fail "$NO_CLOCK"
        return 1
    }
    # Stopped first: on Horizon OS a 2D app left running would stay resumed beside the home, and
    # HOME would get nothing launched
    force_stop "$TARGET_PKG"
    step "pressing HOME: launch 1"
    press_key KEYCODE_HOME
    E2E_FAIL_PREFIX="launch 1: "
    expect_relaunch "$since" "$TARGET_PKG" "$BACK_TIMEOUT" "" || return 1
    for ((n = 1; n <= MAX_LAUNCHES; n++)); do
        crash_target "$n" "$RELAUNCH_TS" || return 1
        if ((n == MAX_LAUNCHES)); then break; fi
        step "crash $n: waiting for launch $((n + 1))"
        expect_relaunch "$CRASH_TS" "$TARGET_PKG" "$BACK_TIMEOUT" "" || return 1
        new_pid=$(pid_of "$TARGET_PKG")
        if [[ -z $new_pid || $new_pid == "$CRASHED_PID" ]]; then
            fail "launch $((n + 1)) did not start a new process (pid ${new_pid:-none}, crashed $CRASHED_PID)"
            return 1
        fi
    done
    step "crash $MAX_LAUNCHES came after the ${MAX_LAUNCHES}th launch in 3 minutes: waiting for 'relaunch throttled'"
    throttle_ts=$(wait_for_log_ts "$BACK_TIMEOUT" "$CRASH_TS" WatchdogService "$throttled_re") || {
        if log_has "$CRASH_TS" WatchdogService "Relaunching $pkg_re \\("; then
            fail "the target was relaunched instead of throttled"
        else
            fail "no '$TARGET_PKG keeps exiting, relaunch throttled' within ${BACK_TIMEOUT} s"
        fi
        return 1
    }
    E2E_FAIL_PREFIX="after crash $MAX_LAUNCHES: "
    step "throttled; waiting for the launch after the cooldown (60 s after launch $MAX_LAUNCHES)"
    expect_relaunch "$CRASH_TS" "$TARGET_PKG" "$COOLDOWN_TIMEOUT" "" || return 1
    # Device times: the first launch after crash 5 must be the one after the cooldown
    after=$(ts_diff "$RELAUNCH_TS" "$CRASH_TS")
    if ts_lt "$after" 45 || ts_lt "$RELAUNCH_TS" "$throttle_ts"; then
        fail "relaunched ${after} s after the crash: nothing should launch for about 60 s after launch $MAX_LAUNCHES"
        return 1
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
    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    trap 'on_signal HUP' HUP
    # A write to a pipe whose reader is gone fails instead of killing the run (log() goes on
    # to run.log). Only this shell: commands it starts get the default back.
    trap : PIPE

    log "Kiosk Launcher e2e: ${#SELECTED[@]} scenario(s): ${SELECTED[*]}"
    log "loader APK: $(rel_path "$LOADER_APK"); results: $(rel_path "$RESULTS_DIR")"
    check_apks
    find_adb
    log "adb: $ADB"
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

    RUN_DONE=yes
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
