package com.osamaalek.kiosklauncher.watchdog

/**
 * Meta Horizon OS dialogs that sit between a launch and the app coming up. Launching the app again
 * while one is open doesn't bring it up, it only uses up the crash-loop budget, so the watchdog
 * waits for the dialog to close instead. Both were seen on a Quest 2 with Horizon OS on Android 14.
 *
 * - The "controllers required" launch check
 *   (com.oculus.vrshell/.systemdialog.launchcheck.LaunchCheckControllerRequiredDialogActivity):
 *   an app that requires controllers isn't started while the headset is used with hands or its
 *   controllers are asleep; Horizon OS starts it once a controller is picked up.
 * - The Guardian (boundary) dialog
 *   (com.oculus.guardian/com.oculus.vrguardianservice.guardiandialog.GuardianDialogActivity),
 *   shown when the headset wakes or is put on, until the boundary is confirmed or set up.
 *
 * Android's own "Allow USB debugging?" prompt
 * (com.android.systemui/.usb.UsbDebuggingActivity) counts too: relaunching the target over it
 * would hide it, and adb could never be authorized again while the loader runs.
 */
object HorizonDialogs {

    private const val SHELL_PACKAGE = "com.oculus.vrshell"
    private const val LAUNCH_CHECK_PREFIX = "com.oculus.vrshell.systemdialog.launchcheck."
    private const val GUARDIAN_PACKAGE = "com.oculus.guardian"
    private const val GUARDIAN_DIALOG_PREFIX = "com.oculus.vrguardianservice.guardiandialog."
    private const val SYSTEMUI_PACKAGE = "com.android.systemui"
    private const val USB_DEBUGGING_PREFIX = "com.android.systemui.usb.UsbDebugging"

    fun isLaunchCheck(packageName: String, className: String) =
        packageName == SHELL_PACKAGE && className.startsWith(LAUNCH_CHECK_PREFIX)

    fun isGuardianDialog(packageName: String, className: String) =
        packageName == GUARDIAN_PACKAGE && className.startsWith(GUARDIAN_DIALOG_PREFIX)

    /** Also matches UsbDebuggingSecondaryUserActivity, shown to a secondary user. */
    fun isUsbDebuggingPrompt(packageName: String, className: String) =
        packageName == SYSTEMUI_PACKAGE && className.startsWith(USB_DEBUGGING_PREFIX)

    /** A dialog that holds launches up, so the watchdog waits for it to close. */
    fun holdsLaunchesUp(packageName: String, className: String) =
        isLaunchCheck(packageName, className) || isGuardianDialog(packageName, className) ||
            isUsbDebuggingPrompt(packageName, className)
}
