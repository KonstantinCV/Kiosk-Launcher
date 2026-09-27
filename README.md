# Kiosk Launcher

A loader for Android devices, built for Meta Quest headsets: it **starts a chosen app when the device boots and relaunches it whenever it exits or crashes**. It was written to run a Headjack app unattended, and works with any launchable app, including Quest VR apps.

It doesn't need device owner, Meta Horizon managed services or a third-party MDM, and the headset keeps its Meta account. It doesn't block the Meta button either: a user can still leave the app, but it comes back after a short grace period.

## How it works

- **Boot:** `BootReceiver` starts `WatchdogService`, a foreground service.
- **Watchdog:** every 2 seconds the service checks which app is in the foreground (from usage stats). If the target has been out of the foreground for the grace period (10 s by default), it launches it again. This covers first boot, a normal exit and a crash.
- **Sleep:** nothing happens while the headset is asleep (display off). The grace period restarts on wake.
- **Crash loops:** after 5 launches in 3 minutes, the watchdog slows to one attempt per minute.
- **Loader UI:** while the loader's own screens are open, the watchdog stands down, so an operator can change settings without the target being launched on top of them.

The loader UI shows the target app, lets you **choose another app**, launch it now, disable the watchdog, change the grace period, pause for 30 minutes, and see which one-time grants are missing.

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

A default target can also be built into the APK: `./gradlew assembleDebug -PloaderTargetPackage=com.example.headjackapp`.

## Building

Android Gradle Plugin 8.7, Kotlin 2.0, JDK 17, compile SDK 35, target SDK 34 (Meta Horizon OS is based on Android 14), min SDK 29.

```sh
./gradlew testDebugUnitTest lintDebug assembleDebug :testapp:assembleDebug
```

This is what CI runs. The loader APK is `app/build/outputs/apk/debug/app-debug.apk`. The `testapp` module is a small target app used only by the end-to-end tests below; it is never shipped.

### Release signing

Every CI run signs `app-debug` with a new throwaway debug key, so a headset can't take a newer CI build over an older one (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`), and uninstalling first wipes the loader's settings. For headsets, use a release build signed with your own key instead. Create the key once and keep a backup of it: without it, no later build can update the headsets.

```sh
keytool -genkeypair -keystore loader-release.jks -alias loader -keyalg RSA -keysize 4096 -validity 10000
base64 -w0 loader-release.jks    # macOS: base64 -i loader-release.jks
```

In the GitHub repository, under *Settings > Secrets and variables > Actions*, add `LOADER_KEYSTORE_BASE64` (the base64 output), `LOADER_KEYSTORE_PASSWORD`, `LOADER_KEY_ALIAS` (`loader`) and `LOADER_KEY_PASSWORD` (the same as the keystore password, since keytool makes PKCS12 keystores by default). CI then also uploads a signed `app-release`. Without the secrets, for example on pull requests from forks, that step is skipped.

To build it locally, set `LOADER_KEYSTORE` to the keystore's path and the other three variables, then run `./gradlew assembleRelease` (they can also go in `~/.gradle/gradle.properties`). Without them, `assembleRelease` gives an unsigned APK. A headset that has a debug build needs `adb uninstall com.osamaalek.kiosklauncher` once before the first release build, then provisioning again.

## Testing

- **Unit tests:** `./gradlew testDebugUnitTest` runs the watchdog's logic (`WatchdogPolicy`, `LaunchBackoff`, `ForegroundState`) on the JVM, and, with Robolectric, the adb command receiver, `TargetLauncher` (including the VR-category fallback) and `LoaderConfig`. The first run downloads Robolectric's Android SDK jar (~150 MB).
- **Lint:** `./gradlew lintDebug` has no findings; `app/lint.xml` lists the checks that are off and why.
- **End-to-end tests:** `e2e/` installs the real loader APK on an Android emulator and drives it only over adb, the way it is used on a Quest: it runs `scripts/provision-quest.sh`, sends the adb commands above, makes a test app exit and crash, presses home, turns the screen off, updates the loader and reboots. 18 scenarios, each checking that the target comes back (or, when it shouldn't, that it doesn't). Relaunches must come from the watchdog seeing the target leave, not from its blind 30 s fallback, and the provisioned grants must be saved to disk and survive an `adb reboot`.

Run them locally on Linux with KVM:

```sh
./gradlew testDebugUnitTest assembleDebug :testapp:assembleDebug
e2e/start-emulator.sh     # headless API 34 emulator; --api 29 for the other CI image
e2e/run.sh                # results in e2e/results/
```

CI runs the same suite on every build, on API 29 (the minimum) and API 34 (what Horizon OS is built on), against the exact `app-debug` APK the build job uploads. Results are on the run page and in the `e2e-results-api29` / `e2e-results-api34` artifacts.

The suite can also run against a real Quest with `e2e/run.sh --allow-real-device --skip reboot` (the `reboot` scenario would reboot the headset). It installs two test apps, changes a few device settings, and leaves the loader in a test configuration: the test app as its target, a 3 s grace period, and possibly disabled or paused if the run was interrupted. That stays until the loader is uninstalled and the headset provisioned again. Running `provision-quest.sh` alone sets the target but keeps the rest, because it reinstalls the loader with `adb install -r`. [e2e/README.md](e2e/README.md#running-on-a-headset) lists how to undo all of it, and covers the scenarios, options and troubleshooting.

## Credits

Based on [Kiosk Launcher](https://github.com/osamaalek/Kiosk-Launcher) by Osama Alek. Licensed under the Apache License 2.0.
