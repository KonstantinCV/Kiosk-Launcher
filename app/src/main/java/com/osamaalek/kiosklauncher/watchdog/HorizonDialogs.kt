package com.osamaalek.kiosklauncher.watchdog

/**
 * System activities that sit between a launch and the app coming up. Seen on a Quest 2 with
 * Horizon OS on Android 14.
 *
 * Dialogs the watchdog waits for, for a while ([isDialogToWaitFor]): launching again while one is
 * open would only bring it back or hide it.
 * - The "controllers required" launch check
 *   (com.oculus.vrshell/.systemdialog.launchcheck.LaunchCheckControllerRequiredDialogActivity):
 *   an app that requires controllers isn't started while the headset is used with hands or its
 *   controllers are asleep; Horizon OS starts it once a controller is picked up.
 * - Android's "Allow USB debugging?" prompt (com.android.systemui/.usb.UsbDebuggingActivity):
 *   relaunching the target over it would hide it, and adb could not be authorized.
 *
 * And one it doesn't wait for ([isGuardianDialog]): Guardian
 * (com.oculus.guardian/com.oculus.vrguardianservice.guardiandialog.GuardianDialogActivity) comes
 * up by itself around a wake, often with nothing shown, and goes away by itself, sometimes without
 * a pause or stop being recorded. While it is in front no launch gets through, so the watchdog
 * keeps trying, but those launches don't count towards the crash-loop guard.
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

    /** A dialog someone has to deal with before the target can come up. */
    fun isDialogToWaitFor(packageName: String, className: String) =
        isLaunchCheck(packageName, className) || isUsbDebuggingPrompt(packageName, className)
}
