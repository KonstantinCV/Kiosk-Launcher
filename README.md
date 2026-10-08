# Kiosk Launcher

A loader for Android devices, built for Meta Quest headsets: it **starts a chosen app when the device boots and relaunches it whenever it exits or crashes**. It was written to run a Headjack app unattended, and works with any launchable app, including Quest VR apps.

It doesn't need device owner, Meta Horizon managed services or a third-party MDM, and the headset keeps its Meta account. It doesn't block the Meta button either: a user can still leave the app, but it comes back after a short grace period.

## How it works

- **Boot:** `BootReceiver` starts `WatchdogService`, a foreground service.
- **Watchdog:** every 2 seconds the service checks whether the target is in the foreground. It reads the activity events Android records for usage stats since boot, and counts the target as in front while any of its activities is resumed, even if another app's activity (a system menu, a second panel) is resumed alongside it. If the target has been out of the foreground for the grace period (10 s by default), it launches it again. This covers first boot, a normal exit and a crash.
- **Sleep:** nothing happens while the headset is asleep (display off). The grace period restarts on wake.
- **Controllers required:** if the target needs controllers and none is active (the headset is used with hands, or the controllers are asleep), Horizon OS shows its "controllers required" dialog instead of starting the app. The watchdog waits while that dialog is open, since launching again would only bring it back, and the app starts once a controller is picked up. For an unattended headset, ask the app's vendor to support hand tracking, or keep a controller awake. The same goes for Android's "Allow USB debugging?" prompt, which a relaunch would otherwise hide. The watchdog waits for either dialog only while it is in front, and for at most a minute; then it launches again, within the crash-loop limit below.
- **Guardian:** around a wake, Horizon OS's Guardian can come up, often with nothing shown, and hold every launch up until it goes away by itself. The watchdog keeps launching meanwhile, but those launches don't count towards the crash-loop limit, so the app comes back as soon as Guardian is gone.
- **Headsets without controllers:** if users get the headset with no controllers and hand tracking off, the only input is the power button: it puts the headset to sleep and wakes it (handled above), and holding it turns the headset off and on (the target starts again on boot). Nobody can quit the target, open the Meta menu or leave the loader's screen, so the loader's screen holds the watchdog back for only 30 s. The target itself must start without a controller: one that doesn't support hand tracking gets the "controllers required" dialog instead, which nobody can dismiss. Check that before deploying (`e2e/quest-check.sh` does, in check 1).
- **Crash loops:** after 5 launches in 3 minutes, the watchdog slows to one attempt per minute.
- **Loader UI:** while an operator is using the loader's own screens, the watchdog stands down, so settings can be changed without the target being launched on top of them. A screen counts as in use only while it is open and was opened or touched in the last 30 seconds: on a Quest a 2D panel stays open beside the home environment until it is closed, and Horizon OS resumes, refocuses and even rebuilds such a panel by itself (after Guardian, or after an immersive app), so a panel left open after setup, or after a quick look, doesn't keep the target from coming back for longer than that. Focus doesn't count either way: without a controller a panel never gets it.

The loader UI shows the target app, lets you **choose another app**, launch it now, disable the watchdog, change the grace period (3 to 300 s), pause for 30 minutes, and see which one-time grants are missing.

**Choosing the app:** on first launch, or whenever the stored target is no longer installed, the loader opens its app list by itself. The list scrolls and shows every launchable app with its icon, name and package name, including Quest VR apps and sideloaded (Unknown Sources) apps; the current target is marked *Current*. Tap one to make it the target. Backing out leaves the target unchanged, and **Choose app** opens the list again. Over adb, `SET_TARGET` (below) does the same.

## Setup on a Quest

The headset needs developer mode and adb access, once, for the grants below. After that it runs on its own.

1. Get the APK: `app-release` from the GitHub Actions run once [release signing](#release-signing) is set up, otherwise `app-debug` (or build it with `./gradlew assembleDebug`).
2. Install the target app (for example your Headjack app) on the headset.
3. Run:

   ```sh
   scripts/provision-quest.sh app/build/outputs/apk/debug/app-debug.apk <target package>
   ```

   Find the target's package name with `adb shell pm list packages`.

The script installs the loader and grants it:

| Grant | Why |
|---|---|
| `appops set <pkg> SYSTEM_ALERT_WINDOW allow` | Android 10+ blocks apps from starting activities from the background. This grant exempts the loader. Device owner is an alternative exemption. |
| `appops set <pkg> GET_USAGE_STATS allow` | Lets the watchdog see the foreground app, to detect exits and crashes. Without it, the target is brought back to the front every 30 s instead. |
| `dumpsys deviceidle whitelist +<pkg>` | Keeps battery optimisation from stopping the service. |
| `settings put global hide_error_dialogs 1` | Hides Android's "has stopped" and "isn't responding" dialogs. They wait for a tap, which nobody can give without a controller or hands; hidden, a crashed app just closes and the watchdog brings it back. |

Right after the two `appops` grants it runs `appops write-settings`, which saves them to disk at once. Android otherwise saves app-op changes about 10 s later, so a reboot or power cut straight after provisioning would lose them. If saving fails, the script warns and carries on; then restart the headset only from its power menu (a clean shutdown saves them), not with `adb reboot` or a forced power-off.

It then sets the target and opens the loader once, which starts the watchdog and makes sure `BOOT_COMPLETED` is delivered from then on.

Android saves the battery optimisation exemption about 5 s after it is set, and nothing can make it save sooner, so the script waits a few seconds before it finishes.

## Commands over adb

Only the adb shell can send these (the receiver requires `WRITE_SECURE_SETTINGS`).

```sh
R=com.osamaalek.kiosklauncher/.receiver.AdminCommandReceiver
A=com.osamaalek.kiosklauncher.action

adb shell am broadcast -n $R -a $A.SET_TARGET --es package com.example.headjackapp
adb shell am broadcast -n $R -a $A.PAUSE --ei minutes 30   # stop relaunching for a while
adb shell am broadcast -n $R -a $A.RESUME
adb shell am broadcast -n $R -a $A.DISABLE                  # or ENABLE
adb shell am broadcast -n $R -a $A.SET_GRACE --ei seconds 15
```

`am broadcast` prints `result=-1, data="OK"` when the command was applied. Otherwise it prints `result=1` and the reason, and nothing is changed. These are rejected:

- `SET_TARGET` with a package that isn't installed or has nothing to launch, or with the loader's own package. Spaces around the name are trimmed first.
- `PAUSE` with `minutes` below 1, or not sent as an int (`--ei`). Without `minutes` it pauses for 30.
- `SET_GRACE` with `seconds` missing, not sent as an int (`--ei`), or outside 3 to 300.

A default target can also be built into the APK: `./gradlew assembleDebug -PloaderTargetPackage=com.example.headjackapp`.

## Building

Android Gradle Plugin 8.7, Kotlin 2.0, JDK 17, compile SDK 35, target SDK 34 (Meta Horizon OS is based on Android 14), min SDK 29.

```sh
./gradlew testDebugUnitTest lintDebug assembleDebug :testapp:assembleDebug
```

This is what CI runs. The loader APK is `app/build/outputs/apk/debug/app-debug.apk`. The `testapp` module is a small target app used only by the end-to-end tests below; it is never shipped.

### Release signing

Every CI run signs `app-debug` with a new throwaway debug key, so a headset can't take a newer CI build over an older one (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`), and uninstalling first wipes the loader's settings. For headsets, use a release build signed with your own key instead. Set it up once, on your own computer:

```sh
scripts/setup-release-signing.sh    # key in ~/kiosk-loader-release.jks; pass another path as the argument
```

It asks for a password, creates the key and prints its SHA-256 fingerprint. If the [GitHub CLI](https://cli.github.com) is installed and logged in (`gh auth login`), it also stores the four secrets CI needs; otherwise it lists them for *Settings > Secrets and variables > Actions*. **Back up the key and its password**: without them no later build can update the headsets.

CI then also uploads a signed `app-release`. Without the secrets, for example on pull requests from forks, that step is skipped. The secrets are `LOADER_KEYSTORE_BASE64` (the keystore, base64), `LOADER_KEYSTORE_PASSWORD`, `LOADER_KEY_ALIAS` (`loader`) and `LOADER_KEY_PASSWORD` (the same as the keystore password). To make the key by hand instead:

```sh
keytool -genkeypair -keystore loader-release.jks -alias loader -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 loader-release.jks    # macOS: base64 -i loader-release.jks
```

To build it locally, set `LOADER_KEYSTORE` to the keystore's path and the other three variables, then run `./gradlew assembleRelease` (they can also go in `~/.gradle/gradle.properties`). Without them, `assembleRelease` gives an unsigned APK. A headset that has a debug build needs `adb uninstall com.osamaalek.kiosklauncher` once before the first release build, then provisioning again.

## Testing

- **Unit tests:** `./gradlew testDebugUnitTest` runs the watchdog's logic (`WatchdogPolicy`, `LaunchBackoff`, `ForegroundState`, `ForegroundTracker` with a fake event source, and all of them together against a simulated device in `WatchdogLoopTest`) on the JVM, and, with Robolectric, the adb command receiver, the settings screen, `TargetLauncher` (including the VR-category fallback) and `LoaderConfig`. The first run downloads Robolectric's Android SDK jar (~150 MB).
- **Lint:** `./gradlew lintDebug` has no findings; `app/lint.xml` lists the checks that are off and why.
- **End-to-end tests:** `e2e/` installs the real loader APK on an Android emulator and drives it only over adb, the way it is used on a Quest: it runs `scripts/provision-quest.sh`, sends the adb commands above, makes a test app exit and crash, presses home, turns the screen off, updates the loader and reboots. 20 scenarios, each checking that the target comes back (or, when it shouldn't, that it doesn't). Relaunches must come from the watchdog seeing the target leave, not from its blind 30 s fallback, and the provisioned grants must be saved to disk and survive an `adb reboot`.

Run them locally on Linux with KVM:

```sh
./gradlew testDebugUnitTest assembleDebug :testapp:assembleDebug
e2e/start-emulator.sh     # headless API 34 emulator; --api 29 for the other CI image
e2e/run.sh                # results in e2e/results/
```

CI runs the same suite on every build, on API 29 (the minimum) and API 34 (what Horizon OS is built on), against the exact `app-debug` APK the build job uploads. Results are on the run page and in the `e2e-results-api29` / `e2e-results-api34` artifacts.

The suite can also run against a real Quest with `e2e/run.sh --allow-real-device --skip reboot` (the `reboot` scenario would reboot the headset). It installs two test apps, changes a few device settings, and leaves the loader in a test configuration: the test app as its target, a 3 s grace period, and possibly disabled or paused if the run was interrupted. That stays until the loader is uninstalled and the headset provisioned again. Running `provision-quest.sh` alone sets the target but keeps the rest, because it reinstalls the loader with `adb install -r`. `e2e/quest-check.sh --target <package>` does all of that in one guided run (the suite, undoing it, provisioning, then the checks only a headset can answer) and packs the results into one zip. [e2e/README.md](e2e/README.md#running-on-a-headset) lists how to undo it by hand, and covers the scenarios, options and troubleshooting.

## Credits

Based on [Kiosk Launcher](https://github.com/osamaalek/Kiosk-Launcher) by Osama Alek. Licensed under the Apache License 2.0.
