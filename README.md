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

1. Build the APK (`./gradlew assembleDebug`, or download `app-debug` from the GitHub Actions run).
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

It then sets the target and opens the loader once, which starts the watchdog and makes sure `BOOT_COMPLETED` is delivered from then on.

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
./gradlew testDebugUnitTest assembleDebug
```

## Credits

Based on [Kiosk Launcher](https://github.com/osamaalek/Kiosk-Launcher) by Osama Alek. Licensed under the Apache License 2.0.
