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
TARGET_ACTIVITY=com.osamaalek.kiosklauncher.testapp.TargetActivity
GUARDIAN_PKG=com.oculus.guardian
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
E2E_FAIL_PREFIX="" # put in front of the running scenario's failure reason, e.g. "crash 3: "
E2E_NOTE=""        # notes of the running scenario, for the summary
TARGET_CMD_OUT=""  # target_cmd: what `am broadcast` printed
APPOPS_OUT=""      # appops_cmd: what `appops` printed
RELAUNCH_TS=""     # expect_relaunch: device time of the relaunch it saw
RELAUNCH_FG=""     # expect_relaunch: the foreground that relaunch logged ("unknown" if blind)

# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------

log() {
    local line
    line="[$(date '+%H:%M:%S')] $*"
    # stderr can be gone (terminal closed, the reader of a pipe killed): run.log still gets it
    printf '%s\n' "$line" >&2 2>/dev/null || true
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

# fail REASON: records the scenario's (first) failure reason, after E2E_FAIL_PREFIX; always
# returns 1
fail() {
    local reason="$E2E_FAIL_PREFIX$*"
    if [[ -z $E2E_FAIL_REASON ]]; then E2E_FAIL_REASON=$reason; fi
    log "    FAIL: $reason"
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

# parse_relaunch_foreground < WatchdogService lines: what the first
# "Relaunching <pkg> (foreground: <fg>)" line says was in front. "unknown" means the watchdog
# could not see the foreground app (no usage access: it relaunches blind). Nothing if no line.
parse_relaunch_foreground() {
    awk '
        !found && / Relaunching [^ ]+ \(foreground: / {
            s = $0
            sub(/^.* Relaunching [^ ]+ \(foreground: /, "", s)
            sub(/\)[ \t]*$/, "", s)
            fg = s
            found = 1
        }
        END { if (found) print fg }
    '
}

# parse_probe_result < E2ETarget lines: "<code> <data>" from the first
# "PROBE_ADMIN result=<code> data=<data>" line, the test app's log of how its ordered DISABLE
# broadcast to the loader ended (data is "null" when there was none). Nothing if no line.
parse_probe_result() {
    awk '
        !found && match($0, /PROBE_ADMIN result=-?[0-9]+ data=/) {
            s = substr($0, RSTART + 19)
            code = s
            sub(/ .*$/, "", code)
            data = s
            sub(/^[^ ]* data=/, "", data)
            sub(/[ \t]+$/, "", data)
            found = 1
        }
        END { if (found) print code " " data }
    '
}

# crash_loop_verdict PKG < WatchdogService and E2ETarget lines (epoch time first), from before
# the watchdog was (re)started: checks the crash loop against LaunchBackoff exactly. From the
# first "Watchdog started" on, it expects
#   launch 1, then crash k followed by launch k+1 for k = 1..4 (one launch per crash, each
#   logging a known foreground), then crash 5 answered by "relaunch throttled" and no launch for
#   at least 45 s, then launch 6 at least 55 s after launch 5 (the 60 s cooldown) and at most
#   80 s after crash 5.
# Prints "ok <counts and timings>", "fail <reason>" for something that went wrong, or
# "incomplete <what is missing>" for a log that stops early; returns 0 for ok, else 1. Stops at
# launch 6.
crash_loop_verdict() {
    awk -v pkg="$1" -v max=5 -v min_gap=55 -v quiet=45 -v late=80 '
        function fail(msg) {
            if (verdict == "") verdict = "fail " msg
            done = 1
        }
        function sec(x) { return sprintf("%.1f", x) }
        function message(line, tag) {
            if (!match(line, " " tag " *: ")) return ""
            return substr(line, RSTART + RLENGTH)
        }
        BEGIN {
            relaunch = "Relaunching " pkg " ("
            throttled = pkg " keeps exiting, relaunch throttled"
            crash = "CRASH pkg=" pkg " pid="
        }
        done { next }
        {
            t = $1 + 0
            m = message($0, "WatchdogService")
            if (m == "") {
                m = message($0, "E2ETarget")
                if (m == "" || index(m, crash) != 1) next
                if (!started) next
                n = crashes + 1
                if (launches != n) {
                    if (launches < n) fail("crash " n " came before launch " n " (" launches " launch(es) so far)")
                    else fail("crash " n " came after " launches " launches: an extra launch")
                    next
                }
                pid = substr(m, length(crash) + 1)
                sub(/[^0-9].*$/, "", pid)
                if (pid in seen) { fail("crash " n " was in pid " pid " again"); next }
                seen[pid] = 1
                crash_at[n] = t
                crashes = n
                next
            }
            if (index(m, "Watchdog started") == 1) {
                if (started) { fail("the watchdog restarted during the crash loop (" launches " launches, " crashes " crashes so far)"); next }
                started = 1
                next
            }
            if (!started) next
            if (m == throttled) {
                if (crashes < max || launches < max) {
                    fail("throttled after only " launches " launches and " crashes " crashes (LaunchBackoff allows " max " launches in 3 minutes)")
                    next
                }
                if (throttles++ == 0) first_throttle = t
                next
            }
            if (index(m, relaunch) != 1) next
            n = launches + 1
            fg = m
            if (!sub(/^.*\(foreground: /, "", fg)) { fail("launch " n ": no foreground in \"" m "\""); next }
            sub(/\)[ \t]*$/, "", fg)
            if (fg == "" || fg == "unknown") {
                fail("launch " n " was blind (foreground: unknown): the watchdog could not see the foreground app")
                next
            }
            if (launches != crashes) { fail("launch " n " came without a crash since launch " launches ": an extra launch"); next }
            if (n <= max) {
                launch_at[n] = t
                launches = n
                next
            }
            # n == max + 1: the launch after the cooldown
            if (throttles == 0) { fail("crash " max " was relaunched without being throttled"); next }
            gap = t - launch_at[max]
            after = t - crash_at[max]
            if (after < quiet) { fail("relaunched " sec(after) " s after crash " max ", expected nothing for at least " quiet " s (cooldown)"); next }
            if (gap < min_gap) { fail("launch " n " came " sec(gap) " s after launch " max ", expected a cooldown of about 60 s"); next }
            if (after > late) { fail("launch " n " came only " sec(after) " s after crash " max ", expected within " late " s"); next }
            launches = n
            verdict = sprintf("ok %d launches, %d crashes: throttled %s s after crash %d (%d throttled checks), launch %d %s s after launch %d (%s s after crash %d)", \
                launches, crashes, sec(first_throttle - crash_at[max]), max, throttles, n, sec(gap), max, sec(after), max)
            done = 1
        }
        END {
            if (verdict == "") {
                if (!started) verdict = "incomplete no \"Watchdog started\" in the log"
                else if (launches == 0) verdict = "incomplete the watchdog never launched the target"
                else if (crashes < max) verdict = "incomplete only " crashes " crash(es) and " launches " launch(es) in the log"
                else if (throttles == 0) verdict = "incomplete no \"relaunch throttled\" after crash " max
                else verdict = "incomplete no launch after the cooldown"
            }
            print verdict
            exit(verdict ~ /^ok / ? 0 : 1)
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

# has_pid PKG: the app has a running process
has_pid() {
    [[ -n "$(pid_of "$1")" ]]
}

# in_front_and_running PKG: PKG is in front and its process is up. dumpsys can report an activity
# in front while Android is still starting its process, so a pid read right after is_foreground
# alone may come back empty.
in_front_and_running() {
    is_foreground "$1" && has_pid "$1"
}

guardian_in_front() {
    is_foreground "$GUARDIAN_PKG"
}

guardian_closed() {
    ! guardian_in_front
}

# wait_guardian_closed TIMEOUT_S: on a Quest, Horizon OS shows its Guardian (boundary) dialog when
# the headset wakes without tracking, and holds every launch up until a person in the headset
# confirms it. Waits for that; returns 1 if it is still open after TIMEOUT_S. No-op elsewhere.
wait_guardian_closed() {
    guardian_in_front || return 0
    step "Horizon OS shows its Guardian dialog; confirm the boundary in the headset (waiting up to $1 s)"
    wait_until "$1" guardian_closed
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

# appops_cmd ARGS...: `appops ARGS` in the device shell, output in APPOPS_OUT. Fails if the
# command fails or the device doesn't know it ("Unknown command: ...").
appops_cmd() {
    local rc=0
    APPOPS_OUT=$(adb_shell appops "$@" 2>&1) || rc=$?
    detail "    appops $*: $(one_line "${APPOPS_OUT:-<no output>}") (exit $rc)"
    ((rc == 0)) && [[ $APPOPS_OUT != *"Unknown command"* && $APPOPS_OUT != *Exception* ]]
}

# appops_save: `appops write-settings`, saves the app ops to disk now. Android otherwise saves a
# change about 10 s later, and `adb reboot` or a power cut (no clean shutdown) before that loses it.
appops_save() {
    appops_cmd write-settings
}

# appops_reload: `appops read-settings`, replaces the app ops in memory with the ones saved on
# disk: afterwards appops get shows what a reboot would start from
appops_reload() {
    appops_cmd read-settings
}

# appops_set_saved PKG OP MODE: sets an app op and saves it right away, so what a reboot keeps is
# what the suite set
appops_set_saved() {
    appops_cmd set "$1" "$2" "$3" && appops_save
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

# broadcast_data AM_OUTPUT: the result data am reported (nothing if there was none)
broadcast_data() {
    local re='result=-?[0-9]+, data="([^"]*)"'
    if [[ $1 =~ $re ]]; then printf '%s\n' "${BASH_REMATCH[1]}"; fi
}

# broadcast_ok AM_OUTPUT: a receiver took it: result=-1 (RESULT_OK), data="OK"
broadcast_ok() {
    [[ "$(broadcast_result "$1")" == -1 && "$(broadcast_data "$1")" == OK ]]
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

# target_cmd ACTION [PKG]: a command for the test app (EXIT, CRASH, PROBE_ADMIN). am's output is
# left in TARGET_CMD_OUT.
target_cmd() {
    local action=$1 pkg=${2:-$TARGET_PKG}
    step "test app: $action ($pkg)"
    TARGET_CMD_OUT=$(adb_shell am broadcast --include-stopped-packages \
        -n "$pkg/$TARGET_RECEIVER" -a "$TARGET_ACTION.$action" 2>&1) || true
    detail "      $(one_line "$TARGET_CMD_OUT")"
    [[ $TARGET_CMD_OUT == *"Broadcast completed"* ]]
}

# bring_target_front: starts the launcher test app's activity, as tapping its panel would. On
# Horizon OS a 2D app stays resumed as a panel beside the home after HOME, so the watchdog rightly
# leaves it alone, but it is no longer in front; scenarios that need it in front bring it back.
bring_target_front() {
    adb_shell am start -n "$TARGET_PKG/$TARGET_ACTIVITY" >/dev/null 2>&1 || true
    wait_until 10 is_foreground "$TARGET_PKG"
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

# relaunched_since SINCE PKG: the watchdog logged a relaunch of PKG after SINCE, and PKG is back:
# in front, its process up, and the test app logged RESUMED after SINCE
relaunched_since() {
    in_front_and_running "$2" &&
        log_has "$1" WatchdogService "Relaunching $(re_escape "$2") \\(" &&
        log_has "$1" "$TARGET_TAG" "$(target_event_re RESUMED "$2")"
}

# expect_relaunch SINCE PKG TIMEOUT_S [LABEL [FOREGROUND]]: waits for the watchdog to bring PKG
# back after SINCE; notes how long the relaunch took ("LABEL in N s", no note if LABEL is "").
# FOREGROUND is what the relaunch's "Relaunching PKG (foreground: <fg>)" line must say:
#   known (default)  anything but "unknown": the watchdog saw what was in front, i.e. it has usage
#                    access and relaunched because the target left, not blind every 30 s
#   unknown          the blind path (no usage access)
#   any              not checked: first launches, where nothing may be known yet
# Sets RELAUNCH_TS (device time of that line) and RELAUNCH_FG.
expect_relaunch() {
    local since=$1 pkg=$2 timeout=$3 label=${4-relaunched} want_fg=${5:-known} fg line pkg_re
    RELAUNCH_TS=""
    RELAUNCH_FG=""
    pkg_re=$(re_escape "$pkg")
    if wait_until "$timeout" relaunched_since "$since" "$pkg"; then
        line=$(log_grep "$since" WatchdogService "Relaunching $pkg_re \\(" | awk 'NR == 1') || line=""
        RELAUNCH_TS=$(printf '%s\n' "$line" | awk '{ print $1 }')
        RELAUNCH_FG=$(printf '%s\n' "$line" | parse_relaunch_foreground)
        if [[ -n $label && -n $RELAUNCH_TS ]]; then note "$label in $(ts_diff "$RELAUNCH_TS" "$since") s"; fi
        case $want_fg in
        known)
            if [[ -z $RELAUNCH_FG || $RELAUNCH_FG == unknown ]]; then
                fail "$pkg was relaunched blind: the watchdog logged 'Relaunching $pkg (foreground: ${RELAUNCH_FG:-?})', so it could not see which app was in front (appops GET_USAGE_STATS of the loader: $(appops_mode "$LOADER_PKG" GET_USAGE_STATS))"
                return 1
            fi
            ;;
        unknown)
            if [[ $RELAUNCH_FG != unknown ]]; then
                fail "the relaunch did not come from the blind path (foreground: ${RELAUNCH_FG:-?}, expected unknown)"
                return 1
            fi
            ;;
        esac
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
