# End-to-end tests

Black-box tests for the loader. They install the real loader APK (the same `app-debug` build CI produces) on an Android emulator and use it only the way it is used on a Quest: `scripts/provision-quest.sh`, the adb commands, key presses, an app that exits or crashes, an update and a reboot. They check what happens on the device (which app is in front, which process runs, what the loader logged and stored), not the loader's code.

The app the loader keeps running is a small test app, the `:testapp` Gradle module, built in two flavors that can be installed side by side:

| APK | Package | Launch entry |
|---|---|---|
| `testapp-launcher-debug.apk` | `com.osamaalek.kiosklauncher.testapp` | `MAIN` + `LAUNCHER`, like an ordinary app. |
| `testapp-vr-debug.apk` | `com.osamaalek.kiosklauncher.testapp.vr` | `MAIN` + `com.oculus.intent.category.VR` only, like a Quest VR app. `getLaunchIntentForPackage()` returns null for it, so the loader has to use its VR fallback. |

The suite controls it with explicit broadcasts to its `CommandReceiver`: `EXIT` (the user closes the app), `CRASH` (an uncaught exception kills the process) and `PROBE_ADMIN` (an ordinary app tries to send the loader an admin command). It logs its lifecycle under the `E2ETarget` tag. It is test-only and never shipped.

## Why AOSP emulator images

Meta Horizon OS is built on AOSP and has no Google services. The emulators use the AOSP `default` system images (not `google_apis` or `google_apis_playstore`), so the loader runs without Google Play services, as it does on a headset. API 29 is the loader's minimum SDK; API 34 is Android 14, which Horizon OS is based on.

An emulator doesn't have the Horizon home or the Meta button (the suite presses the Android home key instead), the proximity sensor that turns the display off when the headset is taken off (it sends `KEYCODE_SLEEP`), or real VR apps (the vr test app only declares the VR category). Those need a headset; see [Running on a headset](#running-on-a-headset).

## Quick start

Needs Linux with KVM (`/dev/kvm`), the Android SDK (`ANDROID_HOME`; `run.sh` uses the `adb` on the `PATH`, else the one in `$ANDROID_HOME/platform-tools`) and JDK 17.

```sh
./gradlew testDebugUnitTest assembleDebug :testapp:assembleDebug
e2e/start-emulator.sh          # API 34; --api 29 for the other CI image
e2e/run.sh
```

`start-emulator.sh [--api LEVEL] [--name AVD]` installs what's missing with `sdkmanager` (emulator, platform-tools, `system-images;android-<api>;default;x86_64`), creates the AVD if it doesn't exist (named `kiosk-e2e-<api>` unless `--name` gives another), starts it headless in the background with its output in `e2e/results/emulator-<api>.log`, waits for boot (up to `E2E_BOOT_TIMEOUT` seconds, default 600) and prints its serial. If that AVD is already running it just prints its serial. Stop it with `adb -s <serial> emu kill`.

Any other emulator works too, for example one started from Android Studio: `run.sh` uses the only attached device, or the one named by `--serial` or `ANDROID_SERIAL`.

To run some scenarios only (`provision` always runs first, and can't be skipped):

```sh
e2e/run.sh --only relaunch-after-crash,screen-off
e2e/run.sh --skip reboot,crash-loop-backoff
```

## Scenarios

They run in this order. Except where a scenario tests it, the grace period is 3 s to keep the run short. "Comes back" means the watchdog logged `Relaunching <pkg>` after the exit, crash or key press, and the target app is the resumed activity again within 30 s; timeouts are generous because CI emulators render in software and are slow.

The watchdog's crash-loop guard allows 5 launches in 3 minutes, then one a minute, and most scenarios make it relaunch the target. So before a scenario that would go over that, `run.sh` restarts the loader (force-stop, open its UI, home), which gives a new watchdog with an empty history; the summary notes "loader restarted first (launch backoff)". Only `crash-loop-backoff` runs into the guard, on purpose.

| # | Scenario | What it proves |
|---|---|---|
| 1 | `provision` | The documented setup works as written. Runs the real `scripts/provision-quest.sh` with the loader and the launcher test app, then checks: exit 0, `SYSTEM_ALERT_WINDOW` and `GET_USAGE_STATS` app-ops are `allow`, the loader is on the deviceidle whitelist, the stored target is the test app, the loader UI is resumed and `WatchdogService` runs as a foreground service. Then sets the grace period to 3 s. |
| 2 | `loader-ui-stands-down` | An operator can use the loader's screens without the target jumping on top: with the loader UI in front for 12 s, the target isn't launched and nothing is logged as relaunched. |
| 3 | `launches-target` | Leaving the loader (home key) is enough: the target starts with no other input. |
| 4 | `relaunch-after-exit` | A normal exit (the app finishes its task) is detected: `Relaunching` is logged and the target comes back. |
| 5 | `relaunch-after-crash` | A crash is detected: the test app throws on its main thread, its process dies, and the target comes back in a new process (new pid). |
| 6 | `relaunch-after-force-stop` | The target comes back after `am force-stop`, as when the system or a user kills it. |
| 7 | `relaunch-after-home` | The target comes back after the user presses home (the Meta button on a Quest) while it is in front. |
| 8 | `grace-period` | The grace period is honoured: with it set to 12 s, an exited target is still gone about 6 s later, and is back within 12 s plus the usual timeout. The grace period is then set back to 3 s. |
| 9 | `pause-resume` | `PAUSE --ei minutes 1` stops relaunches (an exited target stays gone for 12 s) and `RESUME` brings them back. |
| 10 | `disable-enable` | `DISABLE` stops relaunches (12 s) and `ENABLE` brings them back. |
| 11 | `screen-off` | Nothing is launched into a sleeping headset: the target exits and the screen goes off (`KEYCODE_SLEEP`, like taking the headset off); no `Relaunching` for 12 s; after wake-up the target comes back. The grace period is 6 s here, so a slow `input` command can't let a relaunch in before the screen is off; 12 s asleep is still twice that. |
| 12 | `set-target-validation` | `SET_TARGET` with a package that isn't installed is rejected (`result=1`), the stored target doesn't change and the old target is still kept running. |
| 13 | `admin-receiver-protected` | Other apps can't turn the loader off: the test app (an ordinary app without `WRITE_SECURE_SETTINGS`) sends `DISABLE` to `AdminCommandReceiver`; it is never applied, `enabled` isn't set to false, and an exited target is still relaunched. |
| 14 | `vr-target` | Quest VR apps without a `LAUNCHER` entry work as targets: `SET_TARGET` to the vr test app is accepted (the VR fallback in `TargetLauncher`), and the loader switches to it and launches it. The target is then set back to the launcher test app, which comes back. |
| 15 | `blind-mode` | The fallback without usage access works: with `GET_USAGE_STATS` set to `ignore`, an exited target still comes back within the grace period plus the 30 s blind interval (about 50 s). Usage access is restored afterwards. |
| 16 | `package-replaced` | Updating the loader needs no re-provisioning or reboot: `adb install -r` kills it, `MY_PACKAGE_REPLACED` restarts the watchdog without opening the UI, and an exited target comes back. |
| 17 | `reboot` | The boot path works: after `adb reboot` and no interaction, `Watchdog started` is logged and the target is resumed within about 120 s of boot. |
| 18 | `crash-loop-backoff` | A crash-looping app is slowed down but not given up on: the target is crashed right after each relaunch (up to 8 times) until `relaunch throttled` is logged, then it comes back once the cooldown is over (within 80 s, and at least about a minute after the previous launch). The backoff state lives in the watchdog, so this needs a fresh one: after `reboot` it is; without it, the scenario restarts the loader first. |

## Options

```text
e2e/run.sh [--serial S] [--loader-apk PATH] [--target-apk PATH] [--vr-target-apk PATH]
           [--results DIR] [--only a,b] [--skip a,b] [--list] [--allow-real-device]
```

| Option | Default | |
|---|---|---|
| `--serial S` | `$ANDROID_SERIAL`, else the only attached device | Device to test. Fails if no device or more than one is attached. |
| `--loader-apk PATH` | `app/build/outputs/apk/debug/app-debug.apk` | Loader under test. |
| `--target-apk PATH` | `testapp/build/outputs/apk/launcher/debug/testapp-launcher-debug.apk` | Launcher test app. |
| `--vr-target-apk PATH` | `testapp/build/outputs/apk/vr/debug/testapp-vr-debug.apk` | VR test app. |
| `--results DIR` | `e2e/results` | Where the results go (git-ignored). |
| `--only a,b` | | Run only these scenarios, after `provision`. |
| `--skip a,b` | | Run all scenarios except these (not `provision`). |
| `--list` | | Print the scenario names and exit. |
| `--allow-real-device` | | Allow a device that isn't an emulator. See below. |

Relative paths are resolved from the repository root, wherever `run.sh` is called from. It exits 0 only if every selected scenario passed, 1 if one failed, 2 for a usage error or when the run can't start (no device, missing APK) and 130 when interrupted. Except after a usage error, the reports below are always written.

Environment variables for slow machines: `E2E_BACK_TIMEOUT` (seconds for "comes back", default 30), `E2E_POLL` (seconds between checks, default 1) and `E2E_ADB_TIMEOUT` (upper bound for one adb call, default 300).

## What it does to the device

Before the scenarios, and again after the reboot, it prepares the device: waits for boot, turns animations off, keeps the screen on (`svc power stayon true`), turns the lock screen off, wakes the screen and dismisses the keyguard, hides crash and ANR dialogs so they don't cover the target, and makes the log buffer 16 MB.

It then uninstalls the loader and both test apps, installs the test apps and clears the log. The `provision` scenario installs the loader.

## Outputs

In the results directory:

| File | |
|---|---|
| `summary.md` | Table of scenario, result, seconds and a note: the failure reason, or timings such as "relaunched in 3.3 s". CI adds it to the run page. |
| `junit.xml` | One test case per scenario, with the failure message. |
| `run.log` | Everything the runner did and printed. |
| `provision.log` | The output of `scripts/provision-quest.sh`. |
| `logcat.txt` | The device log, taken at the end (from the reboot on, if `reboot` ran). |
| `logcat-before-reboot.txt` | The device log up to the `reboot` scenario. |
| `logcat-<scenario>.txt` | For a failed scenario: the device log while it ran. |
| `screenshot-<scenario>.png` | For a failed scenario: the screen when it failed. |
| `dumpsys-<scenario>.txt` | For a failed scenario: the foreground app, display state, pids, the loader's settings and app-ops, the activity stack and the loader's services. |

The log lines that matter, by tag:

| Tag | Lines |
|---|---|
| `WatchdogService` | `Watchdog started, target=<pkg>`, `Relaunching <pkg> (foreground: <pkg>)`, `<pkg> keeps exiting, relaunch throttled` |
| `TargetLauncher` | `Launched <pkg>`, and warnings when a launch fails |
| `AdminCommandReceiver` | `<action> applied: target=... enabled=... grace=...s pausedUntil=...`, and warnings for rejected commands |
| `E2ETarget` | `CREATED`, `RESUMED`, `PAUSED`, `DESTROYED`, `EXIT`, `CRASH`, `PROBE_ADMIN sent` |

```sh
adb logcat -s WatchdogService TargetLauncher AdminCommandReceiver E2ETarget
```

## Running on a headset

`run.sh` refuses to run on a device that isn't an emulator unless `--allow-real-device` is given. Only use it on a headset you can provision again. On a headset the suite:

- uninstalls the loader, which deletes its settings (target, grace period, pause), and installs it again with the test app as its target;
- installs the two test apps;
- changes device settings: animations off, stay awake, lock screen off, crash dialogs hidden;
- reboots the headset in the `reboot` scenario.

Skip the reboot unless you want it:

```sh
e2e/run.sh --allow-real-device --skip reboot --loader-apk app-debug.apk
```

A Quest turns its display off when it isn't worn, which stops the watchdog, so wear it or cover the proximity sensor while the suite runs. The Horizon home and the Meta button also behave differently from an emulator's home screen, so treat a failure on a headset as something to look into, not proof of a loader bug.

Afterwards, remove the test apps, undo the settings and provision the headset for its real target:

```sh
adb uninstall com.osamaalek.kiosklauncher.testapp
adb uninstall com.osamaalek.kiosklauncher.testapp.vr
adb shell svc power stayon false
adb shell locksettings set-disabled false
adb shell settings put global window_animation_scale 1
adb shell settings put global transition_animation_scale 1
adb shell settings put global animator_duration_scale 1
adb shell settings delete global hide_error_dialogs
scripts/provision-quest.sh app-debug.apk <target package>
```

## CI

`.github/workflows/build.yml` (Build Android App) runs on every push, pull request and manual run:

1. **build** runs `./gradlew testDebugUnitTest assembleDebug :testapp:assembleDebug -PloaderTargetPackage=...`, uploads the loader as `app-debug` and the two test apps as `e2e-target-apks`.
2. **E2E (API 29)** and **E2E (API 34)** download both artifacts, enable KVM on the runner, boot an AOSP `default` x86_64 emulator with [android-emulator-runner](https://github.com/ReactiveCircus/android-emulator-runner) (headless, SwiftShader GPU, no snapshot) and run `bash e2e/run.sh` with the downloaded APKs. The APK under test is exactly the `app-debug` artifact people download.

Both API levels run even if one fails, each with a 45-minute limit. Each adds its `summary.md` to the run page and uploads its results directory as `e2e-results-api29` or `e2e-results-api34`, pass or fail. A newer push to the same branch or pull request cancels the run in progress.

The `target_package` input of a manual run only changes the loader's built-in default target. The suite sets its own target, so it doesn't affect the tests.

## Troubleshooting

- **No `/dev/kvm`:** the x86_64 emulator needs hardware virtualisation, and `start-emulator.sh` stops with an error without it. Run on a Linux host with KVM (on a VM, enable nested virtualisation). If `/dev/kvm` exists but can't be opened, add yourself to the `kvm` group (`sudo usermod -aG kvm $USER`, then log in again); CI does the equivalent with a udev rule.
- **HTTP 429 from Maven Central during the build:** Maven Central rate-limits busy shared IP addresses. Run the build again; if it keeps happening, point Gradle at a mirror with an init script in `~/.gradle/init.d/`.
- **"is not an emulator" or "several devices attached":** see `--allow-real-device` and `--serial`.
- **The emulator doesn't boot:** read `e2e/results/emulator-<api>.log`.
- **A scenario fails or times out:** start with `summary.md` and `run.log`, then that scenario's `logcat-<scenario>.txt`, `screenshot-<scenario>.png` and `dumpsys-<scenario>.txt`. In CI, download `e2e-results-api<level>` from the run page. CI emulators are slow, so a timeout that passes on a re-run is usually the emulator; a scenario that fails the same way every time is worth a look. Re-run it alone with `e2e/run.sh --only <scenario>`.
- **To poke at the test app by hand:**

  ```sh
  adb shell am broadcast -n com.osamaalek.kiosklauncher.testapp/.CommandReceiver \
      -a com.osamaalek.kiosklauncher.testapp.action.EXIT    # or CRASH, PROBE_ADMIN
  ```
