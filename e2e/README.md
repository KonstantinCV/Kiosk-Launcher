# End-to-end tests

Black-box tests for the loader. They install the real loader APK (the same `app-debug` build CI produces) on an Android emulator and use it only the way it is used on a Quest: `scripts/provision-quest.sh`, the adb commands, key presses, an app that exits or crashes, a crash of the loader itself, an update and a reboot. They check what happens on the device (which app is in front, which process runs, what the loader logged and stored), not the loader's code.

The app the loader keeps running is a small test app, the `:testapp` Gradle module, built in two flavors that can be installed side by side:

| APK | Package | Launch entry |
|---|---|---|
| `testapp-launcher-debug.apk` | `com.osamaalek.kiosklauncher.testapp` | `MAIN` + `LAUNCHER`, like an ordinary app. |
| `testapp-vr-debug.apk` | `com.osamaalek.kiosklauncher.testapp.vr` | `MAIN` + `com.oculus.intent.category.VR` only, like a Quest VR app. `getLaunchIntentForPackage()` returns null for it, so the loader has to use its VR fallback. |

The suite controls it with explicit broadcasts to its `CommandReceiver`: `EXIT` (the user closes the app), `CRASH` (an uncaught exception kills the process, half a second after the command so `am` still gets the reply) and `PROBE_ADMIN` (an ordinary app tries to send the loader an admin command; see `admin-receiver-protected`). It logs its lifecycle under the `E2ETarget` tag. It is test-only and never shipped.

## Why AOSP emulator images

Meta Horizon OS is built on AOSP and has no Google services. The emulators use the AOSP `default` system images (not `google_apis` or `google_apis_playstore`), so the loader runs without Google Play services, as it does on a headset. API 29 is the loader's minimum SDK; API 34 is Android 14, which Horizon OS is based on.

An emulator doesn't have the Horizon home or the Meta button (the suite presses the Android home key instead), the proximity sensor that turns the display off when the headset is taken off (it sends `KEYCODE_SLEEP`), or real VR apps (the vr test app only declares the VR category). Those need a headset; see [Running on a headset](#running-on-a-headset).

## Quick start

Needs Linux with KVM (`/dev/kvm`), the Android SDK (`ANDROID_HOME` or `ANDROID_SDK_ROOT`) and JDK 17. Both scripts use the SDK's adb (`platform-tools/adb` under `ANDROID_HOME`, else under `ANDROID_SDK_ROOT`) and fall back to the `adb` on the `PATH`, because two different adb versions keep restarting each other's server. `run.sh` logs which one it uses and runs `provision-quest.sh` with the same one.

```sh
./gradlew testDebugUnitTest assembleDebug :testapp:assembleDebug
e2e/start-emulator.sh          # API 34; --api 29 for the other CI image
e2e/run.sh
```

`start-emulator.sh [--api LEVEL] [--name AVD]` installs what's missing with `sdkmanager` (the emulator, `system-images;android-<api>;default;x86_64`, and platform-tools if there is no adb at all), creates the AVD if it doesn't exist (named `kiosk-e2e-<api>` unless `--name` gives another), starts it headless in the background with its output in `e2e/results/emulator-<api>.log`, waits for boot (up to `E2E_BOOT_TIMEOUT` seconds, default 600) and prints its serial. If that AVD is already running it just prints its serial. Stop it with `adb -s <serial> emu kill`.

Any other emulator works too, for example one started from Android Studio: `run.sh` uses the only attached device, or the one named by `--serial` or `ANDROID_SERIAL`. A device that is still coming online (an emulator that is booting, or a headset whose USB debugging prompt hasn't been accepted yet) gets up to 30 s.

To run some scenarios only (`provision` always runs first, and can't be skipped):

```sh
e2e/run.sh --only relaunch-after-crash,screen-off
e2e/run.sh --skip reboot,crash-loop-backoff
```

## Scenarios

They run in this order. Except where a scenario tests it, the grace period is 3 s to keep the run short. "Comes back" means the watchdog logged `Relaunching <pkg> (foreground: <app>)` after the exit, crash or key press, and the target app is the resumed activity again within 30 s; timeouts are generous because CI emulators render in software and are slow. Timings are taken from the device log.

A relaunch must also name the app that was in front, usually the home screen (`foreground: com.android.launcher3` on the emulators). `foreground: unknown` means the watchdog knew of no resumed activity; after an exit on the emulators, where the home screen always resumes, that means it couldn't see the foreground app (no usage access) and relaunched only because its blind 30 s timer ran out. That fails every scenario except `blind-mode`, which requires it. Launches that don't follow an exit (leaving the loader UI in `launches-target`, a new target in `vr-target`) aren't checked, and the launch right after boot is only noted in the summary.

The watchdog counts the grace period from its own launch until a check (every 2 s) has seen the target in front. So where a scenario times the grace period (`grace-period`, `screen-off` and the exit after `reboot`), it first waits 3 s with the target in front; otherwise it would be timing the launch, not the exit. `target-stays-put` and `loader-crash` wait the same 3 s first, so the watchdog has seen the target in front before they check that it is left alone.

The watchdog's crash-loop guard allows 5 launches in 3 minutes, then one a minute, and most scenarios make it relaunch the target. So before a scenario that would go over that, `run.sh` restarts the loader (force-stop, open its UI, home), which gives a new watchdog with an empty history; the summary notes "loader restarted first (launch backoff)". `crash-loop-backoff` runs into the guard on purpose, and always restarts the loader first.

| # | Scenario | What it proves |
|---|---|---|
| 1 | `provision` | The documented setup works as written, and its grants are saved. Runs the real `scripts/provision-quest.sh` with the loader and the launcher test app, then checks: exit 0; the `SYSTEM_ALERT_WINDOW` and `GET_USAGE_STATS` app-ops are `allow`, and still `allow` after `appops read-settings` reloads the app ops saved on disk (Android saves app-op changes about 10 s late, so a grant only held in memory would be lost by a reboot or power cut right after provisioning); the loader is on the deviceidle whitelist, the stored target is the test app, the loader UI is resumed and `WatchdogService` runs as a foreground service. Then sets the grace period to 3 s. A device without `appops read-settings` fails here. |
| 2 | `loader-ui-stands-down` | An operator can use the loader's screens without the target jumping on top: with the loader UI in front for 12 s, the target isn't launched and nothing is logged as relaunched. |
| 3 | `launches-target` | Leaving the loader (home key) is enough: the target starts with no other input. |
| 4 | `target-stays-put` | A target that stays in front is left alone. After the 3 s wait, nothing may be relaunched for 25 s (more than eight grace periods), and the target must still be in front, in the same process. Launching an app that is already in front starts no new process and leaves the same app in front (Android hands the intent to the activity on top, pausing and resuming a singleTask app such as a Unity app for it), so a watchdog that lost track of a target in front would show only in its log, as `Relaunching` every grace period. |
| 5 | `relaunch-after-exit` | A normal exit (the app finishes its task) is detected: `Relaunching` is logged and the target comes back. |
| 6 | `relaunch-after-crash` | A crash is detected: the test app throws on its main thread, its process dies, and the target comes back in a new process (new pid). |
| 7 | `relaunch-after-force-stop` | The target comes back after `am force-stop`, as when the system or a user kills it. |
| 8 | `relaunch-after-home` | The target comes back after the user presses home (the Meta button on a Quest) while it is in front. |
| 9 | `grace-period` | The grace period is honoured: with it set to 12 s, and after the 3 s wait above, an exited target is still gone 6 s later and is relaunched 11.5 to 18 s after the exit (usually 12 to 14 s, 16 s if a check just missed the exit). The grace period is then set back to 3 s. |
| 10 | `pause-resume` | `PAUSE --ei minutes 1` stops relaunches (an exited target stays gone for 12 s) and `RESUME` brings them back. |
| 11 | `disable-enable` | `DISABLE` stops relaunches (12 s) and `ENABLE` brings them back. |
| 12 | `screen-off` | Nothing is launched into a sleeping headset: after the 3 s wait, the target exits and the screen goes off (`KEYCODE_SLEEP`, like taking the headset off); no `Relaunching` for 12 s; after wake-up the target comes back. The grace period is 6 s here, so a slow `input` command can't let a relaunch in before the screen is off; 12 s asleep is still twice that. |
| 13 | `set-target-validation` | `SET_TARGET` with a package that isn't installed is rejected (`result=1`), the stored target doesn't change and the old target is still kept running. |
| 14 | `admin-receiver-protected` | Other apps can't turn the loader off. As a control, `ENABLE` from the adb shell must get `result=-1, data="OK"` from `AdminCommandReceiver`. Then the test app (an ordinary app without `WRITE_SECURE_SETTINGS`) sends it `DISABLE` as an ordered broadcast that starts with result code 42 and data `untouched`, and logs how the broadcast ended. It must log `PROBE_ADMIN result=42 data=untouched`: no receiver ran (the loader's would have set `-1` and `OK`). `DISABLE` must not be logged as applied, `enabled` must still be true, and an exited target is still relaunched. API 29 also logs a permission denial, which the summary notes; API 34 logs nothing. |
| 15 | `vr-target` | Quest VR apps without a `LAUNCHER` entry work as targets: `SET_TARGET` to the vr test app is accepted (the VR fallback in `TargetLauncher`), and the loader switches to it and launches it. The target is then set back to the launcher test app, which comes back. |
| 16 | `blind-mode` | The fallback without usage access works: with `GET_USAGE_STATS` set to `ignore`, an exited target still comes back within the grace period plus the 30 s blind interval (about 50 s), and the relaunch logs `foreground: unknown`. Usage access is restored afterwards. Both changes are saved right away (`appops write-settings`) and the restored grant is read back from disk, so `reboot` starts from the provisioned grants. |
| 17 | `package-replaced` | Updating the loader needs no re-provisioning or reboot: `adb install -r` kills it, `MY_PACKAGE_REPLACED` restarts the watchdog without opening the UI, and an exited target comes back. |
| 18 | `loader-crash` | The watchdog survives a crash of the loader itself, with nobody there to open its UI. With the target in front (after the 3 s wait), `am crash com.osamaalek.kiosklauncher` crashes the loader; if the device refuses that, or it has no effect within 10 s, `run-as com.osamaalek.kiosklauncher kill -9 <pid>` kills it instead, and the summary says which one did it. The process must die, and Android must restart the sticky foreground service by itself, without the loader UI opening: `WatchdogService` runs as a foreground service again and the new process logs `Watchdog started`. That normally takes about a second (the summary gives the time); up to 40 s is allowed, because recent Android versions (14 among them) wait 10 to 30 s longer under memory pressure. The new watchdog starts from nothing but what it reads from the system, and must see that the target is already in front: nothing may be relaunched for 12 s (four grace periods), and the target stays in front in the same process. Then an exited target must come back with a known foreground. A new watchdog has an empty launch history, so this doesn't touch the crash-loop guard. The loader is crashed only once: after a second crash within a minute or two, Android waits 30 minutes before restarting the service. |
| 19 | `reboot` | The boot path works, and the provisioned state survives an unclean restart: `adb reboot` skips the framework's shutdown, like a power cut. With no interaction, `Watchdog started` is logged and the target is resumed within 120 s of boot. Then both app-ops must still be `allow`, the loader must still be on the deviceidle whitelist and the stored target must still be the test app. After the 3 s wait, an exited target must be relaunched with a known foreground (a watchdog that lost usage access would only relaunch blind, every 30 s). With `--only reboot` it first waits until 6 s after provisioning, because Android saves the deviceidle whitelist 5 s after a change. |
| 20 | `crash-loop-backoff` | A crash-looping app is slowed down but not given up on, exactly as the guard says. The loader is restarted (a new watchdog, with an empty launch history) and HOME gets launch 1. The target is then crashed 5 times, each time in the process that is in front and logged `RESUMED` after the last launch; that process must log `CRASH pkg=<pkg> pid=<pid>` and die. Crashes 1 to 4 must each get exactly one relaunch, in a new process. Crash 5 follows the 5th launch in 3 minutes, so it must get `relaunch throttled` and no relaunch. The next launch must come after the cooldown: at least 45 s after crash 5, at least 55 s after launch 5 and within 80 s of crash 5. Finally the whole log from `Watchdog started` is checked again: 6 launches for 5 crashes, 5 different pids, no blind launch, no early throttle and no watchdog restart. The summary gives the counts and timings. |

## Options

```text
e2e/run.sh [--serial S] [--loader-apk PATH] [--target-apk PATH] [--vr-target-apk PATH]
           [--results DIR] [--only a,b] [--skip a,b] [--list] [--allow-real-device]
```

| Option | Default | |
|---|---|---|
| `--serial S` | `$ANDROID_SERIAL`, else the only attached device | Device to test. A device adb lists but can't use yet (offline, unauthorized), or the one named here, gets up to 30 s to come online. With nothing attached, or several devices and no serial, the run stops at once. |
| `--loader-apk PATH` | `app/build/outputs/apk/debug/app-debug.apk` | Loader under test. |
| `--target-apk PATH` | `testapp/build/outputs/apk/launcher/debug/testapp-launcher-debug.apk` | Launcher test app. |
| `--vr-target-apk PATH` | `testapp/build/outputs/apk/vr/debug/testapp-vr-debug.apk` | VR test app. |
| `--results DIR` | `e2e/results` | Where the results go (git-ignored). |
| `--only a,b` | | Run only these scenarios, after `provision`. |
| `--skip a,b` | | Run all scenarios except these (not `provision`). |
| `--list` | | Print the scenario names and exit. |
| `--allow-real-device` | | Allow a device that isn't an emulator. See below. |

Relative paths are resolved from the repository root, wherever `run.sh` is called from.

It exits 0 only if every selected scenario passed, 1 if one failed, 2 for a usage error or when the run can't start (no usable device, missing APK, the test apps don't install), and 129, 130 or 143 when stopped by SIGHUP (the terminal closed), SIGINT (Ctrl-C) or SIGTERM. If the runner stops on an unexpected error, it never exits 0.

Except after a usage error, the reports below are always written, and a scenario that didn't finish never counts as passed. When the run is stopped by a signal, the running scenario fails as `interrupted (SIGHUP)` (or whichever signal it was) and the rest as `not run: interrupted (...)`. The reports are rewritten after each scenario, so reports read while the run is going, or left by a run that was killed outright, list the scenarios still to come as failed under a **Run not finished** line.

Environment variables for slow machines: `E2E_BACK_TIMEOUT` (seconds for "comes back", default 30), `E2E_POLL` (seconds between checks, default 1) and `E2E_ADB_TIMEOUT` (upper bound for one adb call, default 300).

## What it does to the device

Before the scenarios, and again after the reboot, it prepares the device: waits for boot, turns animations off, keeps the screen on (`svc power stayon true`), turns the lock screen off, wakes the screen and dismisses the keyguard, hides crash and ANR dialogs so they don't cover the target, and makes the log buffer 16 MB.

It then uninstalls the loader and both test apps, installs the test apps and clears the log. The `provision` scenario installs the loader.

Every app-op change the suite makes is saved to disk right away (`appops write-settings`). To check the saved grants, `provision` runs `appops read-settings`, which replaces the app ops of every app in memory with the ones on disk. `provision-quest.sh` has saved them all a few seconds before, so at most a change another app made in between is undone.

## Outputs

In the results directory:

| File | |
|---|---|
| `summary.md` | Table of scenario, result, seconds and a note: the failure reason, or timings such as "relaunched in 3.3 s". A failure in the middle of a scenario says where, for example `crash 3: ...`. CI adds it to the run page. |
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
| `WatchdogService` | `Watchdog started, target=<pkg>`, `Relaunching <pkg> (foreground: <pkg or unknown>)`, `<pkg> keeps exiting, relaunch throttled` (once each time the throttle starts), `<pkg> is not installed or has no launchable activity` (once per target), and `Watchdog check failed` with a stack trace if a check throws (at most once a minute) |
| `TargetLauncher` | `Launched <pkg>`, and warnings when a launch fails |
| `AdminCommandReceiver` | `<action> applied: target=... enabled=... grace=...s pausedUntil=...`, and warnings for rejected commands |
| `E2ETarget` | `CREATED`, `RESUMED`, `PAUSED`, `DESTROYED` and `CRASH` (each `pkg=<pkg> pid=<pid>`), `EXIT pkg=<pkg>`, `PROBE_ADMIN sent`, `PROBE_ADMIN result=<code> data=<data>` |
| `E2ERunner` | The runner's marks, such as `=== scenario <name> ===`, which separate the scenarios in the saved logs |

```sh
adb logcat -s WatchdogService TargetLauncher AdminCommandReceiver E2ETarget E2ERunner
```

## Running on a headset

`run.sh` refuses to run on a device that isn't an emulator unless `--allow-real-device` is given. Only use it on a headset you can provision again. On a headset the suite:

- uninstalls the loader, which deletes its settings (target, grace period, pause), and installs it again with the test app as its target and a 3 s grace period;
- installs the two test apps;
- changes device settings: animations off, stay awake, lock screen off, crash and ANR dialogs hidden;
- reboots the headset in the `reboot` scenario.

Skip the reboot unless you want it:

```sh
e2e/run.sh --allow-real-device --skip reboot
```

That uses the APKs from a local build (`./gradlew assembleDebug :testapp:assembleDebug`). To test a CI build instead, download the run's `app-debug` and `e2e-target-apks` artifacts and pass them:

```sh
e2e/run.sh --allow-real-device --skip reboot --loader-apk app-debug.apk \
    --target-apk testapp-launcher-debug.apk --vr-target-apk testapp-vr-debug.apk
```

A Quest turns its display off when it isn't worn, which stops the watchdog, so wear it or cover the proximity sensor while the suite runs. On many Horizon OS versions `adb shell am broadcast -a com.oculus.vrpowermanager.prox_close` keeps it on as if worn until the next reboot; `adb shell am broadcast -a com.oculus.vrpowermanager.automation_disable` undoes it. The Horizon home and the Meta button also behave differently from an emulator's home screen, so treat a failure on a headset as something to look into, not proof of a loader bug.

Afterwards the loader is still set up for the tests: the test app as its target, a 3 s grace period, and disabled or paused if the run stopped in the middle of a scenario. Running `provision-quest.sh` again sets the new target but keeps the rest, because it reinstalls the loader with `adb install -r`. So uninstall the loader first, then remove the test apps, undo the settings and provision the headset for its real target:

```sh
adb uninstall com.osamaalek.kiosklauncher
adb uninstall com.osamaalek.kiosklauncher.testapp
adb uninstall com.osamaalek.kiosklauncher.testapp.vr
adb shell svc power stayon false
adb shell locksettings set-disabled false
adb shell settings put global window_animation_scale 1
adb shell settings put global transition_animation_scale 1
adb shell settings put global animator_duration_scale 1
adb shell settings delete global hide_error_dialogs
adb shell settings delete global show_first_crash_dialog
adb shell settings delete secure show_first_crash_dialog_dev_option
adb shell settings delete secure anr_show_background
scripts/provision-quest.sh app-debug.apk <target package>
```

### Manual checks on a Quest

Some things only a headset can answer: whether Horizon OS lets the grants do their job, and how its own UI shows up to the watchdog. After the automated run above, uninstall and provision the headset for its real target (the commands above), then keep a log running in a second terminal:

```sh
adb logcat -c
adb logcat -v time WatchdogService:I TargetLauncher:I AdminCommandReceiver:I ActivityTaskManager:I '*:S' | tee -a quest-checks.log
```

A restart ends the log command. Start it again (without `adb logcat -c`) once the headset is back: logcat first prints what was logged since boot, so the boot launch is still captured, and `tee -a` appends to the same file.

| # | Do | Expect |
|---|---|---|
| 1 | Restart the headset from its power menu. | The target starts on its own shortly after the home environment appears: `Watchdog started`, then `Relaunching <target>`. |
| 2 | Restart it with `adb reboot` (like a power cut). | The same. `adb shell appops get com.osamaalek.kiosklauncher` still shows `SYSTEM_ALERT_WINDOW: allow` and `GET_USAGE_STATS: allow`. |
| 3 | Quit the target from its own menu. | It comes back after the grace period (10 s). The log line reads `(foreground: <some package>)`, not `(foreground: unknown)`. If it reads `unknown`, check `adb shell appops get com.osamaalek.kiosklauncher GET_USAGE_STATS`: with `allow`, Horizon reported no activity resumed after the exit, which is worth noting. |
| 4 | `adb shell am crash <target package>` (or `am force-stop`). | It comes back after the grace period. |
| 5 | Open the Meta (universal) menu over the target and leave it open for 15 s. | Note what happens: the menu may count as leaving the target, and the target is brought back over it after 10 s. Say whether that is acceptable. Right after opening the menu, `adb shell dumpsys usagestats \| grep -E 'ACTIVITY_(RESUMED\|PAUSED)' \| tail -5` shows how Horizon reports it. |
| 6 | Take the headset off for 30 s, then put it back on. | Nothing is launched while the display is off; the target is still there, or comes back within the grace period. |
| 7 | Open the loader from the app library and wait 15 s. | Nothing is launched over the loader's own screen. |
| 8 | Start the target for the first time, before it has been granted its runtime permissions (if it asks for any), and leave its permission prompt open for 15 s. | Note whether the watchdog closes the prompt by relaunching the target. Installing the target with `adb install -g` grants those permissions up front, so no prompt appears. |

Send back `quest-checks.log`, the `e2e/results/` folder from the automated run, the headset's Horizon OS version (`adb shell getprop ro.build.display.id`) and a note per check.

## CI

`.github/workflows/build.yml` (Build Android App) runs on every push, pull request and manual run:

1. **build** runs `./gradlew testDebugUnitTest lintDebug assembleDebug :testapp:assembleDebug -PloaderTargetPackage=...`, uploads the loader as `app-debug` and the two test apps as `e2e-target-apks`.
2. **E2E (API 29)** and **E2E (API 34)** download both artifacts, enable KVM on the runner, boot an AOSP `default` x86_64 emulator with [android-emulator-runner](https://github.com/ReactiveCircus/android-emulator-runner) (headless, SwiftShader GPU, no snapshot) and run `bash e2e/run.sh` with the downloaded APKs. The APK under test is exactly the `app-debug` artifact people download.

Both API levels run even if one fails, each with a 45-minute limit. Each adds its `summary.md` to the run page and uploads its results directory as `e2e-results-api29` or `e2e-results-api34`, pass or fail. A newer run of the same kind for the same branch or pull request cancels the one in progress: a push cancels an older push's run, a manual run an older manual run. A manual run and a push don't cancel each other.

The `target_package` input of a manual run only changes the loader's built-in default target. The suite sets its own target, so it doesn't affect the tests.

## Troubleshooting

- **No `/dev/kvm`:** the x86_64 emulator needs hardware virtualisation, and `start-emulator.sh` stops with an error without it. Run on a Linux host with KVM (on a VM, enable nested virtualisation). If `/dev/kvm` exists but can't be opened, add yourself to the `kvm` group (`sudo usermod -aG kvm $USER`, then log in again); CI does the equivalent with a udev rule.
- **HTTP 429 from Maven Central during the build:** Maven Central rate-limits busy shared IP addresses. Run the build again; if it keeps happening, point Gradle at a mirror with an init script in `~/.gradle/init.d/`.
- **"is not an emulator" or "several devices attached":** see `--allow-real-device` and `--serial`.
- **"no usable device after 30 s" or "is not available after 30 s":** adb lists the device but can't use it. The message says what to do for its state: `unauthorized` (accept the USB debugging prompt in the headset), `offline` (reconnect it, or `adb reconnect offline`) or `no permissions` (the host's udev rules).
- **The emulator doesn't boot:** read `e2e/results/emulator-<api>.log`.
- **"was relaunched blind":** the relaunch logged `foreground: unknown`, so the loader had no usage access. Check it with `adb shell appops get com.osamaalek.kiosklauncher GET_USAGE_STATS`.
- **"the grant was only in memory" in `provision`:** `provision-quest.sh` didn't save the grants. Its warning, if saving failed, is in `provision.log`.
- **"did not log 'PROBE_ADMIN result=...'" in `admin-receiver-protected`:** the test app APK is older than the suite. Build it again with `./gradlew :testapp:assembleDebug`.
- **A scenario fails or times out:** start with `summary.md` and `run.log`, then that scenario's `logcat-<scenario>.txt`, `screenshot-<scenario>.png` and `dumpsys-<scenario>.txt`. In CI, download `e2e-results-api<level>` from the run page. CI emulators are slow, so a timeout that passes on a re-run is usually the emulator; a scenario that fails the same way every time is worth a look. Re-run it alone with `e2e/run.sh --only <scenario>`.
- **To poke at the test app by hand:**

  ```sh
  adb shell am broadcast -n com.osamaalek.kiosklauncher.testapp/.CommandReceiver \
      -a com.osamaalek.kiosklauncher.testapp.action.EXIT    # or CRASH, PROBE_ADMIN
  ```
