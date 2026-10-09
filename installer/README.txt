Kiosk Loader for Meta Quest
===========================

Starts the chosen app when the headset boots and brings it back within seconds whenever it
closes or crashes. Built for headsets that users get without controllers or hand tracking.

What's in this folder
  kiosk-loader.apk     the loader
  install.sh           sets up one headset (macOS or Linux)
  provision-quest.sh   used by install.sh

You need
  - adb (Android platform tools). macOS: brew install --cask android-platform-tools
  - On the headset: developer mode on (Meta Horizon phone app > the headset > Developer mode)
  - The app to keep running, already installed on the headset

Set up a headset
  1. Connect it with a USB cable, put it on, and allow USB debugging. Tick
     "Always allow from this computer", so restarts don't lose the connection.
  2. In this folder, run:

       bash install.sh

     It lists the apps on the headset; type the number of the one to keep running.
     Or name it, and set how long it may be gone before it is started again (0 to 60 s):

       bash install.sh --target com.example.app --grace 3

     With more than one headset connected, add --serial <serial> (see: adb devices).
  3. On the headset, once: turn the boundary (Guardian) off in Settings, and, if users get it
     that way, hand tracking off and the controllers away.
  4. Restart the headset (hold the power button until it turns off, then turn it on). The app
     should start by itself.

What install.sh changes on the headset
  - Installs the loader and lets it start apps from the background and see which app is in front
  - Keeps battery saving from stopping it
  - Hides Android's "has stopped" / "isn't responding" dialogs, which nobody could tap away
  - Turns the lock screen off (only possible while the headset has no PIN, pattern or password)
  - Sets the app to keep running, and starts the loader

Afterwards
  - The loader's own screen (in the app library: Kiosk Launcher) shows the app, lets you pick
    another one, change the relaunch delay, pause for 30 minutes or switch the loader off.
  - Over adb, without the headset on:
      adb shell am broadcast -n com.osamaalek.kiosklauncher/.receiver.AdminCommandReceiver \
          -a com.osamaalek.kiosklauncher.action.PAUSE --ei minutes 30
    (other actions: RESUME, ENABLE, DISABLE, SET_GRACE --ei seconds N,
     SET_TARGET --es package <app>)
  - To remove it: adb uninstall com.osamaalek.kiosklauncher

Keep developer mode on: the loader's permissions were granted over adb.
