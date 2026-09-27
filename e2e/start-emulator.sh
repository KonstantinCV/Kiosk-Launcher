#!/usr/bin/env bash
# Starts a headless Android emulator for the e2e suite and prints its adb serial:
#
#   serial=$(e2e/start-emulator.sh --api 34)
#   e2e/run.sh --serial "$serial"
#
# Options: --api LEVEL (default 34), --name AVD (default kiosk-e2e-<api>).
# Installs what is missing with sdkmanager (emulator, platform-tools and the AOSP "default"
# x86_64 system image: Meta Horizon OS is AOSP-based without Google services, so no Google APIs
# image), creates the AVD if needed, starts it in the background (log in
# e2e/results/emulator-<api>.log) and waits for boot. If that AVD is already running, prints its
# serial. Needs a Linux host with KVM. Progress goes to stderr, only the serial to stdout.
set -euo pipefail

API=34
NAME=""
BOOT_TIMEOUT=${E2E_BOOT_TIMEOUT:-600}

usage() {
    cat <<'EOF'
Usage: e2e/start-emulator.sh [--api LEVEL] [--name AVD]

Starts a headless emulator for e2e/run.sh and prints its adb serial.
  --api LEVEL   Android API level of the system image (default: 34)
  --name AVD    AVD name (default: kiosk-e2e-<api>)

Needs ANDROID_HOME (or ANDROID_SDK_ROOT) with the command-line tools, and KVM (/dev/kvm).
EOF
}

die() {
    printf 'start-emulator: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

while (($# > 0)); do
    case $1 in
    --api)
        (($# >= 2)) || die "--api needs a value"
        API=$2
        shift 2
        ;;
    --api=*)
        API=${1#*=}
        shift
        ;;
    --name)
        (($# >= 2)) || die "--name needs a value"
        NAME=$2
        shift 2
        ;;
    --name=*)
        NAME=${1#*=}
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *) die "unknown option: $1 (see --help)" ;;
    esac
done

[[ $API =~ ^[0-9]+$ ]] || die "--api needs an API level, e.g. 34"
NAME=${NAME:-kiosk-e2e-$API}
[[ $NAME =~ ^[A-Za-z0-9._-]+$ ]] || die "AVD names may only contain letters, digits, '.', '_' and '-'"

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
RESULTS_DIR=$REPO_ROOT/e2e/results
LOG_FILE=$RESULTS_DIR/emulator-$API.log
IMAGE="system-images;android-$API;default;x86_64"

# --- Hardware acceleration --------------------------------------------------------------------
if [[ $(uname -s) != Linux ]]; then
    die "this helper supports Linux hosts with KVM. Elsewhere, start an emulator from Android Studio and run: e2e/run.sh --serial <serial>"
fi
if [[ ! -e /dev/kvm ]]; then
    die "/dev/kvm not found: the emulator needs KVM. Enable virtualization (VT-x/AMD-V) in the firmware, or nested virtualization for a VM, and load the kvm module (e.g. sudo modprobe kvm_intel)"
fi
if [[ ! -r /dev/kvm || ! -w /dev/kvm ]]; then
    die "no permission to use /dev/kvm: add yourself to the kvm group (sudo usermod -aG kvm \"\$USER\", then log in again)"
fi

# --- SDK --------------------------------------------------------------------------------------
SDK=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}
[[ -n $SDK && -d $SDK ]] || die "set ANDROID_HOME to your Android SDK directory"

# sdk_tool NAME: sdkmanager / avdmanager from the command-line tools
sdk_tool() {
    local candidate
    for candidate in "$SDK/cmdline-tools/latest/bin/$1" "$SDK"/cmdline-tools/*/bin/"$1" "$SDK/tools/bin/$1"; do
        if [[ -x $candidate ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    command -v "$1" 2>/dev/null
}

missing=()
[[ -x $SDK/emulator/emulator ]] || missing+=(emulator)
[[ -x $SDK/platform-tools/adb ]] || missing+=(platform-tools)
[[ -d $SDK/system-images/android-$API/default/x86_64 ]] || missing+=("$IMAGE")
if ((${#missing[@]} > 0)); then
    SDKMANAGER=$(sdk_tool sdkmanager) ||
        die "sdkmanager not found: install the Android SDK command-line tools into $SDK/cmdline-tools/latest"
    info "installing ${missing[*]} (accepting the SDK licenses)"
    # `yes` dies of SIGPIPE when sdkmanager is done; only sdkmanager's status matters
    set +o pipefail
    if ! yes | "$SDKMANAGER" --sdk_root="$SDK" --install "${missing[@]}" >&2; then
        die "sdkmanager could not install ${missing[*]}"
    fi
    set -o pipefail
fi
EMULATOR=$SDK/emulator/emulator
ADB=$SDK/platform-tools/adb

# --- AVD --------------------------------------------------------------------------------------
avds=$("$EMULATOR" -list-avds 2>/dev/null || true)
if ! printf '%s\n' "$avds" | tr -d '\r' | grep -Fx -- "$NAME" >/dev/null; then
    AVDMANAGER=$(sdk_tool avdmanager) ||
        die "avdmanager not found: install the Android SDK command-line tools into $SDK/cmdline-tools/latest"
    info "creating AVD $NAME from $IMAGE"
    # "Do you wish to create a custom hardware profile?" -> no
    echo no | "$AVDMANAGER" create avd --name "$NAME" --package "$IMAGE" >&2 ||
        die "avdmanager could not create $NAME"
fi

# --- Already running? -------------------------------------------------------------------------
"$ADB" start-server >/dev/null 2>&1 || true
devices=$("$ADB" devices 2>/dev/null | awk 'NR > 1 && NF >= 2 { print $1 }')

boot_completed() {
    [[ "$("$ADB" -s "$1" shell getprop sys.boot_completed 2>/dev/null </dev/null | tr -d '\r')" == 1 ]]
}

# wait_for_boot SERIAL [PID]: until sys.boot_completed=1; fails early if PID exits
wait_for_boot() {
    local serial=$1 pid=${2:-} deadline=$((SECONDS + BOOT_TIMEOUT))
    info "waiting for $serial to boot (up to $BOOT_TIMEOUT s)"
    while ! boot_completed "$serial"; do
        if [[ -n $pid ]] && ! kill -0 "$pid" 2>/dev/null; then
            tail -n 30 "$LOG_FILE" >&2 || true
            die "the emulator exited while booting; see ${LOG_FILE#"$REPO_ROOT"/}"
        fi
        if ((SECONDS >= deadline)); then
            die "$serial did not boot within $BOOT_TIMEOUT s; see ${LOG_FILE#"$REPO_ROOT"/}"
        fi
        sleep 3
    done
}

for serial in $devices; do
    [[ $serial == emulator-* ]] || continue
    running=$("$ADB" -s "$serial" emu avd name 2>/dev/null </dev/null | tr -d '\r' | awk 'NR == 1 { n = $0 } END { print n }')
    if [[ $running == "$NAME" ]]; then
        info "$NAME is already running as $serial"
        wait_for_boot "$serial"
        printf '%s\n' "$serial"
        exit 0
    fi
done

# --- Start ------------------------------------------------------------------------------------
port=5554
while printf '%s\n' "$devices" | grep -Fx -- "emulator-$port" >/dev/null; do
    port=$((port + 2))
    ((port <= 5682)) || die "no free emulator port between 5554 and 5682"
done
SERIAL=emulator-$port

mkdir -p "$RESULTS_DIR"
info "starting $NAME as $SERIAL (log: ${LOG_FILE#"$REPO_ROOT"/})"
emulator_args=(-avd "$NAME" -port "$port" -no-window -no-audio -no-boot-anim -no-snapshot -gpu swiftshader_indirect)
# In its own session when possible, so Ctrl-C here or closing the terminal doesn't kill it
if command -v setsid >/dev/null 2>&1; then
    setsid nohup "$EMULATOR" "${emulator_args[@]}" >"$LOG_FILE" 2>&1 </dev/null &
else
    nohup "$EMULATOR" "${emulator_args[@]}" >"$LOG_FILE" 2>&1 </dev/null &
fi
EMULATOR_PID=$!

wait_for_boot "$SERIAL" "$EMULATOR_PID"
info "$SERIAL booted. Stop it with: $ADB -s $SERIAL emu kill"
printf '%s\n' "$SERIAL"
