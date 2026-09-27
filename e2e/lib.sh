#!/usr/bin/env bash
# Helpers for the end-to-end suite. Sourced by e2e/run.sh, not run on its own.
#
# Everything here talks to one device ($E2E_SERIAL) over adb. Conventions:
#  - predicates (is_*, *_running, log_has, ...) return 0/1 and print nothing;
#  - readers (foreground_pkg, pid_of, prefs_get, ...) print their result on stdout;
#  - progress goes to stderr and run.log, so it never ends up inside a $(...) capture.
# Written for bash 3.2+ (macOS) and POSIX awk (mawk, gawk, BSD awk).
set -euo pipefail

# --- The loader under test (app/src/main/AndroidManifest.xml) --------------------------------
LOADER_PKG=com.osamaalek.kiosklauncher
LOADER_MAIN=$LOADER_PKG/.ui.MainActivity
LOADER_ADMIN=$LOADER_PKG/.receiver.AdminCommandReceiver
LOADER_ACTION=$LOADER_PKG.action

# --- The test target app (testapp/, test-only, never shipped) --------------------------------
TARGET_PKG=com.osamaalek.kiosklauncher.testapp       # "launcher" flavor: MAIN + LAUNCHER
# shellcheck disable=SC2034 # used by run.sh
VR_TARGET_PKG=com.osamaalek.kiosklauncher.testapp.vr # "vr" flavor: MAIN + com.oculus.intent.category.VR only
TARGET_RECEIVER=com.osamaalek.kiosklauncher.testapp.CommandReceiver
TARGET_ACTION=com.osamaalek.kiosklauncher.testapp.action
TARGET_TAG=E2ETarget
RUNNER_TAG=E2ERunner

# --- Runtime settings (run.sh sets these) ----------------------------------------------------
ADB=${ADB:-adb}
E2E_SERIAL=${E2E_SERIAL:-}
RUN_LOG=${RUN_LOG:-/dev/null}
E2E_POLL=${E2E_POLL:-1}         # seconds between polls in wait_until
ADB_TIMEOUT=${E2E_ADB_TIMEOUT:-300} # upper bound for one adb call, if `timeout` is available
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)
DEVICE_CLOCK_MS=no # probe_device_clock: whether `date +%s.%N` gives sub-second time on the device
LOGCAT_SINCE=yes   # probe_logcat: whether `logcat -t <epoch>.<ms>` works on the device
E2E_FAIL_REASON="" # first failure of the running scenario
E2E_NOTE=""        # notes of the running scenario, for the summary

# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------

log() {
    local line
    line="[$(date '+%H:%M:%S')] $*"
    printf '%s\n' "$line" >&2
    printf '%s\n' "$line" >>"$RUN_LOG" 2>/dev/null || true
}

# detail LINE...: goes to run.log only
detail() {
    printf '%s\n' "$@" >>"$RUN_LOG" 2>/dev/null || true
}

step() { log "    $*"; }

# one_line TEXT: TEXT on a single line, whitespace squeezed, at most 400 characters
one_line() {
    local s
    s=$(printf '%s' "$1" | tr -s '\r\n\t ' ' ')
    s=${s# }
    s=${s% }
    if ((${#s} > 400)); then s="${s:0:400}..."; fi
    printf '%s\n' "$s"
}

# note TEXT: adds TEXT to the running scenario's summary note
note() {
    E2E_NOTE=${E2E_NOTE:+$E2E_NOTE; }$*
    step "note: $*"
}

# fail REASON: records the scenario's (first) failure reason; always returns 1
fail() {
    if [[ -z $E2E_FAIL_REASON ]]; then E2E_FAIL_REASON=$*; fi
    log "    FAIL: $*"
    return 1
}

# ---------------------------------------------------------------------------------------------
# Pure helpers (no device)
# ---------------------------------------------------------------------------------------------

# re_escape TEXT: TEXT with ERE metacharacters escaped (package names: the dots)
re_escape() {
    # shellcheck disable=SC2016 # the $ is a literal character to escape
    printf '%s\n' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'
}

# target_event_re EVENT PKG: matches the test app's "<EVENT> pkg=<PKG>[ pid=<pid>]" log message
target_event_re() {
    printf '%s pkg=%s( |$)\n' "$1" "$(re_escape "$2")"
}

# xml_escape TEXT: TEXT escaped for XML text and attribute values, invalid control chars dropped
xml_escape() {
    printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' |
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

# md_cell TEXT: TEXT made safe for a markdown table cell
md_cell() {
    one_line "$1" | sed -e 's/|/\\|/g' -e 's/</\&lt;/g'
}

# ts_diff A B: A - B for epoch timestamps, one decimal
ts_diff() {
    awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f\n", (a + 0) - (b + 0) }'
}

# ts_lt A B: whether number A < number B
ts_lt() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit !((a + 0) < (b + 0)) }'
}

# parse_resumed_package < `dumpsys activity activities`: the package of the resumed activity.
# API 34: "topResumedActivity=ActivityRecord{c0ffee1 u0 <pkg>/.A t12}" and
#         "ResumedActivity: ActivityRecord{...}";
# API 29: "mResumedActivity: ActivityRecord{...}" and " ResumedActivity:ActivityRecord{...}".
# Prefers topResumedActivity, then ResumedActivity, then mResumedActivity. Lines whose record is
# null are skipped.
parse_resumed_package() {
    awk '
        function pkg_of(line,    s) {
            if (!match(line, "ActivityRecord[{][^}]* u[0-9]+ [^ /}]+/")) return ""
            s = substr(line, RSTART, RLENGTH - 1)
            sub(/.* u[0-9]+ /, "", s)
            return s
        }
        /^[ \t]*topResumedActivity[ \t]*[=:]/ { if (top == "") top = pkg_of($0); next }
        /^[ \t]*mResumedActivity[ \t]*[=:]/   { if (mres == "") mres = pkg_of($0); next }
        /^[ \t]*ResumedActivity[ \t]*[=:]/    { if (res == "") res = pkg_of($0); next }
        END {
            if (top != "") print top
            else if (res != "") print res
            else if (mres != "") print mres
        }
    '
}

# parse_focused_package < `dumpsys window`: the package of the focused window (mCurrentFocus),
# else of the focused app (mFocusedApp). Fallback for parse_resumed_package.
parse_focused_package() {
    awk '
        function pkg_of(line,    s) {
            if (!match(line, " u[0-9]+ [^ /}]+/")) return ""
            s = substr(line, RSTART, RLENGTH - 1)
            sub(/^ u[0-9]+ /, "", s)
            return s
        }
        /^[ \t]*mCurrentFocus=/ { if (cf == "") cf = pkg_of($0); next }
        /^[ \t]*mFocusedApp=/   { if (fa == "") fa = pkg_of($0); next }
        END {
            if (cf != "") print cf
            else if (fa != "") print fa
        }
    '
}

# parse_watchdog_foreground < `dumpsys activity services <loader>`: succeeds if the
# ServiceRecord of WatchdogService says isForeground=true. The record header can end in
# "WatchdogService}" or, on API 31+, "WatchdogService c:<caller>}".
parse_watchdog_foreground() {
    awk -v pkg="$LOADER_PKG" '
        {
            line = $0
            match(line, /^ */)
            indent = RLENGTH
            if (line ~ /^[ \t]*\* ServiceRecord[{]/) {
                inblock = (index(line, " " pkg "/") > 0 && line ~ /WatchdogService[ }]/)
                next
            }
            if (line ~ /[^ \t]/ && indent <= 3) { inblock = 0; next }
            if (inblock && line ~ /isForeground=true/) found = 1
        }
        END { exit(found ? 0 : 1) }
    '
}

# parse_appops_mode OP < `appops get <pkg> <OP>`: the package mode (allow, ignore, deny, ...)
# from "OP: allow; time=..." (a preceding "Uid mode: OP: ..." line is overridden)
parse_appops_mode() {
    awk -v op="$1" '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/^Uid mode: /, "", line)
            if (index(line, op ": ") == 1) {
                m = substr(line, length(op) + 3)
                sub(/;.*$/, "", m)
                sub(/[ \t]+$/, "", m)
                mode = m
            }
        }
        END { print mode }
    '
}

# parse_pref KEY < shared_prefs XML: the value of KEY, nothing if absent.
#   <string name="target_package">com.example</string>  <boolean name="enabled" value="true" />
parse_pref() {
    awk -v key="$1" '
        index($0, "name=\"" key "\"") > 0 {
            line = $0
            if (match(line, /value="[^"]*"/)) v = substr(line, RSTART + 7, RLENGTH - 8)
            else if (match(line, />[^<]*</)) v = substr(line, RSTART + 1, RLENGTH - 2)
            else v = ""
            found = 1
        }
        END { if (found) print v }
    '
}

# parse_wakefulness < `dumpsys power`: Awake, Asleep, Dozing or Dreaming
parse_wakefulness() {
    awk '
        /^[ \t]*mWakefulness=/ {
            if (w == "") { w = $0; sub(/^[ \t]*mWakefulness=/, "", w); sub(/[ \t].*$/, "", w) }
            next
        }
        /Display Power: state=/ {
            if (d == "") { d = $0; sub(/.*Display Power: state=/, "", d); sub(/[ \t].*$/, "", d) }
        }
        END {
            if (w != "") print w
            else if (d == "ON") print "Awake"
            else if (d != "") print "Asleep"
        }
    '
}

# ---------------------------------------------------------------------------------------------
# adb
# ---------------------------------------------------------------------------------------------

# adb_ ARGS...: adb for the selected device. Never reads the caller's stdin (adb shell would
# otherwise forward it), and gives up after ADB_TIMEOUT seconds if `timeout` is available.
adb_() {
    if [[ -n $TIMEOUT_BIN ]]; then
        "$TIMEOUT_BIN" "$ADB_TIMEOUT" "$ADB" -s "$E2E_SERIAL" "$@" </dev/null
    else
        "$ADB" -s "$E2E_SERIAL" "$@" </dev/null
    fi
}

# adb_shell ARGS...: a device shell command, output without the CRs some devices add.
# The exit code is the device command's (adb propagates it; pipefail keeps it).
adb_shell() {
    adb_ shell "$@" | tr -d '\r'
}

device_online() {
    [[ "$("$ADB" -s "$E2E_SERIAL" get-state 2>/dev/null </dev/null)" == device ]]
}

device_prop() {
    adb_shell getprop "$1" 2>/dev/null || true
}

# boot_ready: online, sys.boot_completed=1 and the package manager answers
boot_ready() {
    device_online || return 1
    [[ "$(device_prop sys.boot_completed)" == 1 ]] || return 1
    adb_ shell pm path android >/dev/null 2>&1
}

# boot_id: changes on every boot (empty if the device doesn't let the shell read it)
boot_id() {
    adb_shell cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

device_is_emulator() {
    local kernel_qemu boot_qemu hardware
    kernel_qemu=$(device_prop ro.kernel.qemu)
    boot_qemu=$(device_prop ro.boot.qemu)
    hardware=$(device_prop ro.hardware)
    [[ $kernel_qemu == 1 || $boot_qemu == 1 || $hardware == goldfish || $hardware == ranchu ]]
}

# wait_until TIMEOUT_S COMMAND [ARGS...]: runs COMMAND every E2E_POLL s until it succeeds
# (returns 0) or TIMEOUT_S seconds have passed (returns 1)
wait_until() {
    local timeout=$1 deadline
    shift
    deadline=$((SECONDS + timeout))
    while true; do
        if "$@"; then return 0; fi
        if ((SECONDS >= deadline)); then return 1; fi
        sleep "$E2E_POLL"
    done
}

# expect_within TIMEOUT_S MESSAGE COMMAND [ARGS...]: wait_until, failing the scenario on timeout
expect_within() {
    local timeout=$1 message=$2
    shift 2
    if wait_until "$timeout" "$@"; then return 0; fi
    fail "$message (waited ${timeout} s)"
}

# ---------------------------------------------------------------------------------------------
# Device log. Timestamps are the device's epoch clock as "<seconds>.<millis>", which is also
# what `logcat -v epoch` prints, so only lines logged after a mark are looked at.
# ---------------------------------------------------------------------------------------------

# device_epoch: the device clock, e.g. 1727430000.123 (".000" if the device has no %N)
device_epoch() {
    local out
    out=$(adb_shell 'date +%s.%N' 2>/dev/null) || return 1
    out=${out%%$'\n'*}
    if [[ $out =~ ^([0-9]+)\.([0-9][0-9][0-9]) ]]; then
        printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ $out =~ ^([0-9]+) ]]; then
        printf '%s.000\n' "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

probe_device_clock() {
    local t
    t=$(device_epoch) || t=""
    if [[ -n $t && $t != *.000 ]]; then DEVICE_CLOCK_MS=yes; else DEVICE_CLOCK_MS=no; fi
}

# log_mark [LABEL]: prints a mark for log_since: the lines logged from now on are "since" it.
# Also writes LABEL to logcat (tag E2ERunner) so the saved logs are easy to follow.
log_mark() {
    local label=${1:-mark} out t
    label=${label//[^A-Za-z0-9 _.:=,-]/_}
    out=$(adb_shell "date +%s.%N; log -t $RUNNER_TAG '=== $label ===' >/dev/null 2>&1; true" 2>/dev/null) ||
        return 1
    out=${out%%$'\n'*}
    if [[ $DEVICE_CLOCK_MS == yes && $out =~ ^([0-9]+)\.([0-9][0-9][0-9]) ]]; then
        t="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    elif [[ $out =~ ^([0-9]+) ]]; then
        # Whole seconds only: step to the next second so nothing logged before the mark counts
        t="$((BASH_REMATCH[1] + 1)).000"
        sleep 1
    else
        return 1
    fi
    printf '%s\n' "$t"
}

# log_since SINCE [TAG...]: logcat lines (threadtime format, epoch time first) logged at or
# after SINCE, only from the given tags if any
log_since() {
    local since=$1 out
    shift
    local args=(logcat -d -v threadtime -v epoch)
    if [[ $LOGCAT_SINCE == yes ]]; then args+=(-t "$since"); fi
    if (($# > 0)); then args+=(-s "$@"); fi
    out=$(adb_ "${args[@]}" 2>/dev/null) || return 1
    printf '%s\n' "$out" | tr -d '\r' | awk -v since="$since" '($1 + 0) >= (since + 0)'
}

# probe_logcat: checks that the log helpers see a line written right now, with and then without
# the server-side time filter
probe_logcat() {
    local mark lines
    for LOGCAT_SINCE in yes no; do
        mark=$(log_mark "probe") || return 1
        adb_shell "log -t $RUNNER_TAG 'probe line $mark'" >/dev/null 2>&1 || true
        lines=$(log_since "$mark" "$RUNNER_TAG") || lines=""
        if [[ $lines == *"probe line $mark"* ]]; then return 0; fi
    done
    LOGCAT_SINCE=yes
    return 1
}

# log_grep SINCE TAG ERE: lines of TAG since SINCE whose message starts with ERE
log_grep() {
    local lines
    lines=$(log_since "$1" "$2") || return 1
    printf '%s\n' "$lines" | grep -E -- " $2 *: $3" || true
}

log_has() {
    local lines
    lines=$(log_grep "$@") || return 1
    [[ -n $lines ]]
}

# log_first_ts / log_last_ts SINCE TAG ERE: epoch time of the first / last matching line
log_first_ts() {
    log_grep "$@" | awk 'NR == 1 { t = $1 } END { print t }'
}

log_last_ts() {
    log_grep "$@" | awk '{ t = $1 } END { print t }'
}

# wait_for_log_ts TIMEOUT_S SINCE TAG ERE: waits for a matching line, prints its epoch time
wait_for_log_ts() {
    local timeout=$1 since=$2 tag=$3 re=$4 deadline ts
    deadline=$((SECONDS + timeout))
    while true; do
        ts=$(log_first_ts "$since" "$tag" "$re") || ts=""
        if [[ -n $ts ]]; then
            printf '%s\n' "$ts"
            return 0
        fi
        if ((SECONDS >= deadline)); then return 1; fi
        sleep "$E2E_POLL"
    done
}

# ---------------------------------------------------------------------------------------------
# Device state
# ---------------------------------------------------------------------------------------------

# foreground_pkg: package of the resumed activity (empty if none, e.g. display off)
foreground_pkg() {
    local out pkg
    out=$(adb_shell dumpsys activity activities 2>/dev/null) || out=""
    pkg=$(printf '%s\n' "$out" | parse_resumed_package)
    if [[ -z $pkg ]]; then
        out=$(adb_shell dumpsys window 2>/dev/null) || out=""
        pkg=$(printf '%s\n' "$out" | parse_focused_package)
    fi
    printf '%s\n' "$pkg"
}

is_foreground() {
    [[ "$(foreground_pkg)" == "$1" ]]
}

# pid_of PKG: the app's process id, empty if it isn't running
pid_of() {
    local out
    out=$(adb_shell pidof "$1" 2>/dev/null) || out=""
    printf '%s\n' "${out%%[[:space:]]*}"
}

# pid_not PKG PID: the app's process is no longer PID (gone or restarted)
pid_not() {
    [[ "$(pid_of "$1")" != "$2" ]]
}

package_installed() {
    adb_ shell pm path "$1" >/dev/null 2>&1
}

force_stop() {
    adb_shell am force-stop "$1" >/dev/null 2>&1 || true
}

press_key() {
    adb_shell input keyevent "$1" >/dev/null 2>&1 || true
}

wakefulness() {
    local out
    out=$(adb_shell dumpsys power 2>/dev/null) || out=""
    printf '%s\n' "$out" | parse_wakefulness
}

# is_awake / is_asleep: PowerManager.isInteractive() is true when Awake or Dreaming
is_awake() {
    local w
    w=$(wakefulness)
    [[ $w == Awake || $w == Dreaming ]]
}

is_asleep() {
    local w
    w=$(wakefulness)
    [[ $w == Asleep || $w == Dozing ]]
}

wake_device() {
    adb_shell 'input keyevent KEYCODE_WAKEUP; wm dismiss-keyguard' >/dev/null 2>&1 || true
}

watchdog_running() {
    local out
    out=$(adb_shell dumpsys activity services "$LOADER_PKG" 2>/dev/null) || return 1
    printf '%s\n' "$out" | parse_watchdog_foreground
}

watchdog_stopped() {
    ! watchdog_running
}

appops_mode() {
    local out
    out=$(adb_shell appops get "$1" "$2" 2>/dev/null) || out=""
    printf '%s\n' "$out" | parse_appops_mode "$2"
}

in_deviceidle_whitelist() {
    local out
    out=$(adb_shell dumpsys deviceidle whitelist 2>/dev/null) || return 1
    [[ $'\n'$out$'\n' == *",$1,"* ]]
}

# prefs_xml: the loader's shared_prefs/loader.xml (the debug APK is debuggable, so run-as works)
prefs_xml() {
    adb_shell run-as "$LOADER_PKG" cat shared_prefs/loader.xml 2>/dev/null
}

# prefs_get KEY: a loader setting as stored (empty if never written)
prefs_get() {
    local xml
    xml=$(prefs_xml) || return 1
    printf '%s\n' "$xml" | parse_pref "$1"
}

pref_is() {
    local value
    value=$(prefs_get "$1") || return 1
    [[ $value == "$2" ]]
}

pref_positive() {
    local value
    value=$(prefs_get "$1") || return 1
    [[ $value =~ ^[0-9]+$ ]] && ((value > 0))
}

# expect_pref KEY VALUE [TIMEOUT_S]: SharedPreferences.apply() writes the file asynchronously
expect_pref() {
    local key=$1 want=$2 timeout=${3:-10} value
    if wait_until "$timeout" pref_is "$key" "$want"; then return 0; fi
    value=$(prefs_get "$key") || value="<unreadable>"
    fail "loader setting $key is '$value', expected '$want'"
}

# ---------------------------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------------------------

# admin_broadcast ACTION [EXTRAS...]: a loader admin command sent as the adb shell (which holds
# WRITE_SECURE_SETTINGS); prints am's output, e.g. `Broadcast completed: result=-1, data="OK"`
admin_broadcast() {
    local action=$1
    shift
    adb_shell am broadcast -n "$LOADER_ADMIN" -a "$LOADER_ACTION.$action" "$@" 2>&1
}

# broadcast_result AM_OUTPUT: the result code am reported
broadcast_result() {
    local re='result=(-?[0-9]+)'
    if [[ $1 =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

# admin_try ACTION [EXTRAS...]: sends the command, succeeds on result=-1 (RESULT_OK)
admin_try() {
    local out
    out=$(admin_broadcast "$@") || true
    detail "    admin $*: $(one_line "$out")"
    [[ "$(broadcast_result "$out")" == -1 ]]
}

# admin_cmd ACTION [EXTRAS...]: like admin_try, failing the scenario if it isn't accepted
admin_cmd() {
    local out
    out=$(admin_broadcast "$@") || true
    if [[ "$(broadcast_result "$out")" == -1 ]]; then
        step "admin $*: OK"
        return 0
    fi
    fail "admin command $* was not accepted: $(one_line "$out")"
}

# target_cmd ACTION [PKG]: a command for the test app (EXIT, CRASH, PROBE_ADMIN)
target_cmd() {
    local action=$1 pkg=${2:-$TARGET_PKG} out
    step "test app: $action ($pkg)"
    out=$(adb_shell am broadcast --include-stopped-packages \
        -n "$pkg/$TARGET_RECEIVER" -a "$TARGET_ACTION.$action" 2>&1) || true
    detail "      $(one_line "$out")"
    [[ $out == *"Broadcast completed"* ]]
}

open_loader_ui() {
    adb_shell am start -n "$LOADER_MAIN" >/dev/null 2>&1 || true
    wait_until 30 is_foreground "$LOADER_PKG"
}

# ---------------------------------------------------------------------------------------------
# Expectations shared by the scenarios
# ---------------------------------------------------------------------------------------------

expect_foreground() {
    local pkg=$1 timeout=$2 what=${3:-$1} fg
    if wait_until "$timeout" is_foreground "$pkg"; then return 0; fi
    fg=$(foreground_pkg)
    fail "$what not in the foreground after ${timeout} s (foreground: ${fg:-none})"
}

# relaunched_since SINCE PKG: the watchdog logged a relaunch of PKG after SINCE, and PKG is resumed
relaunched_since() {
    is_foreground "$2" && log_has "$1" WatchdogService "Relaunching $(re_escape "$2") \\("
}

# expect_relaunch SINCE PKG TIMEOUT_S [LABEL]: waits for the watchdog to bring PKG back after
# SINCE; notes how long the relaunch took ("LABEL in N s")
expect_relaunch() {
    local since=$1 pkg=$2 timeout=$3 label=${4:-relaunched} fg rel_ts pkg_re
    pkg_re=$(re_escape "$pkg")
    if wait_until "$timeout" relaunched_since "$since" "$pkg"; then
        rel_ts=$(log_first_ts "$since" WatchdogService "Relaunching $pkg_re \\(") || rel_ts=""
        if [[ -n $rel_ts ]]; then note "$label in $(ts_diff "$rel_ts" "$since") s"; fi
        return 0
    fi
    fg=$(foreground_pkg)
    if log_has "$since" WatchdogService "$pkg_re keeps exiting, relaunch throttled"; then
        fail "relaunch of $pkg was throttled (foreground: ${fg:-none})"
    elif log_has "$since" WatchdogService "Relaunching $pkg_re \\("; then
        fail "the watchdog relaunched $pkg but it was not resumed within ${timeout} s (foreground: ${fg:-none})"
    else
        fail "$pkg was not relaunched within ${timeout} s (foreground: ${fg:-none})"
    fi
}

# recent_launches: how many launches the running watchdog made in the last 3 minutes, i.e. what
# its LaunchBackoff counts (5 in 3 minutes, then one per minute): "Relaunching" lines, counted
# from its last "Watchdog started" (the backoff is per service instance)
recent_launches() {
    local now lines
    now=$(device_epoch) || return 1
    lines=$(log_since "$(awk -v n="$now" 'BEGIN { printf "%.3f\n", n - 180 }')" WatchdogService) || return 1
    printf '%s\n' "$lines" | awk '
        / WatchdogService *: Watchdog started/ { n = 0; next }
        / WatchdogService *: Relaunching / { n++ }
        END { print n + 0 }
    '
}

# target_left_since SINCE PKG: PKG is out of the foreground, or logged that it was paused
target_left_since() {
    ! is_foreground "$2" || log_has "$1" "$TARGET_TAG" "$(target_event_re PAUSED "$2")"
}

# expect_stays_away SINCE WAIT_S WHY: nothing is relaunched for WAIT_S seconds
expect_stays_away() {
    local since=$1 wait_s=$2 why=$3 fg
    step "checking that nothing is relaunched for ${wait_s} s ($why)"
    sleep "$wait_s"
    if log_has "$since" WatchdogService "Relaunching"; then
        fail "the watchdog relaunched the target $why"
        return 1
    fi
    fg=$(foreground_pkg)
    if [[ $fg == "$TARGET_PKG" ]]; then
        fail "the target came back $why"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------------------------
# Device preparation
# ---------------------------------------------------------------------------------------------

# prep_device: idempotent; run again after a reboot
prep_device() {
    step "waiting for boot to complete"
    if ! wait_until 300 boot_ready; then
        log "device $E2E_SERIAL did not finish booting within 300 s"
        return 1
    fi
    step "disabling animations, keeping the screen on, dismissing the lock screen and error dialogs"
    local cmds=(
        "settings put global window_animation_scale 0"
        "settings put global transition_animation_scale 0"
        "settings put global animator_duration_scale 0"
        "svc power stayon true"
        "locksettings set-disabled true"
        "input keyevent KEYCODE_WAKEUP"
        "wm dismiss-keyguard"
        "settings put global hide_error_dialogs 1"
        "settings put global show_first_crash_dialog 0"
        "settings put secure show_first_crash_dialog_dev_option 0"
        "settings put secure anr_show_background 0"
    )
    local cmd
    for cmd in "${cmds[@]}"; do
        # Each one on its own: some fail on some devices (locksettings with a PIN), which is fine
        if ! adb_shell "$cmd" >>"$RUN_LOG" 2>&1; then detail "    (ignored failure: $cmd)"; fi
    done
    # A bigger log buffer, so a long scenario's lines are still there when they are checked
    adb_ logcat -G 16M >/dev/null 2>&1 || true
    return 0
}
