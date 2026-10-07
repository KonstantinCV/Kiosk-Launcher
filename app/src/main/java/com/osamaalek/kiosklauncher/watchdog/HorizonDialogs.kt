package com.osamaalek.kiosklauncher.watchdog

/**
 * Meta Horizon OS dialogs that sit between a launch and the app coming up.
 *
 * An app that requires controllers is not started while the headset is used with hands, or its
 * controllers are asleep: Horizon OS shows its "controllers required" launch check instead
 * (com.oculus.vrshell/.systemdialog.launchcheck.LaunchCheckControllerRequiredDialogActivity,
 * seen on a Quest 2 with Horizon OS on Android 14) and starts the app once a controller is
 * picked up. Launching the app again while it is open only brings the dialog back, so the
 * watchdog waits for it to close instead.
 */
object HorizonDialogs {

    private const val SHELL_PACKAGE = "com.oculus.vrshell"
    private const val LAUNCH_CHECK_PREFIX = "com.oculus.vrshell.systemdialog.launchcheck."

    fun isLaunchCheck(packageName: String, className: String) =
        packageName == SHELL_PACKAGE && className.startsWith(LAUNCH_CHECK_PREFIX)
}
