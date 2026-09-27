package com.osamaalek.kiosklauncher.testapp

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log

/**
 * Lets the e2e suite (e2e/) make the target misbehave. Test-only: never shipped. Example:
 *
 *   adb shell am broadcast -n com.osamaalek.kiosklauncher.testapp/.CommandReceiver \
 *       -a com.osamaalek.kiosklauncher.testapp.action.EXIT
 *
 * The action names are the same in both flavors.
 */
class CommandReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_EXIT -> {
                Log.i(TargetActivity.TAG, "EXIT pkg=${context.packageName}")
                // What a user leaving the app does: the activity and its task go away.
                val activity = TargetActivity.current()
                if (activity != null) {
                    activity.finishAndRemoveTask()
                } else {
                    Log.i(TargetActivity.TAG, "No TargetActivity to finish")
                }
            }
            ACTION_CRASH -> {
                context.logEvent("CRASH")
                // Thrown a moment later rather than here, so adb still gets the broadcast result.
                // The result goes to the system in a one-way call that a crash right after it can
                // overtake: adb then prints result=0 although the app did crash (seen in CI on
                // API 29 and 34). Uncaught, it kills the process like any real crash.
                Handler(Looper.getMainLooper()).postDelayed(
                    { throw RuntimeException("E2E induced crash") },
                    CRASH_DELAY_MS,
                )
            }
            ACTION_PROBE_ADMIN -> {
                // This app doesn't hold WRITE_SECURE_SETTINGS, so the system must drop this
                // before it reaches the loader. Ordered, so the outcome shows on every API level
                // (API 34 logs nothing when it drops it): the loader's receiver would set -1/"OK",
                // a dropped broadcast ends with the initial code and data. ProbeResultReceiver
                // logs how it ended.
                context.sendOrderedBroadcast(
                    Intent(LOADER_ACTION_DISABLE).setComponent(LOADER_ADMIN_RECEIVER),
                    null, // receiverPermission
                    ProbeResultReceiver(),
                    null, // scheduler: the main thread
                    PROBE_INITIAL_CODE,
                    PROBE_INITIAL_DATA,
                    null, // initialExtras
                )
                Log.i(TargetActivity.TAG, "PROBE_ADMIN sent")
            }
            else -> {
                Log.w(TargetActivity.TAG, "Unknown action ${intent.action}")
                reply(RESULT_ERROR, "Unknown action ${intent.action}")
                return
            }
        }
        reply(Activity.RESULT_OK, "OK")
    }

    // `am broadcast` waits for a result and prints it, like it does for the loader's commands
    private fun reply(code: Int, data: String) {
        if (isOrderedBroadcast) {
            resultCode = code
            resultData = data
        }
    }

    /**
     * Gets PROBE_ADMIN's broadcast once every receiver has had it, and logs how it ended:
     * "PROBE_ADMIN result=42 data=untouched" if nothing handled it, "result=-1 data=OK" if the
     * loader's AdminCommandReceiver did.
     */
    private class ProbeResultReceiver : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            Log.i(TargetActivity.TAG, "PROBE_ADMIN result=$resultCode data=${resultData ?: "null"}")
        }
    }

    companion object {
        private const val PREFIX = "com.osamaalek.kiosklauncher.testapp.action."

        const val ACTION_EXIT = PREFIX + "EXIT"
        const val ACTION_CRASH = PREFIX + "CRASH"
        const val ACTION_PROBE_ADMIN = PREFIX + "PROBE_ADMIN"

        private const val RESULT_ERROR = 1

        private const val CRASH_DELAY_MS = 500L

        // What PROBE_ADMIN's broadcast starts with, and still has if no receiver ran
        private const val PROBE_INITIAL_CODE = 42
        private const val PROBE_INITIAL_DATA = "untouched"

        private const val LOADER_ACTION_DISABLE = "com.osamaalek.kiosklauncher.action.DISABLE"
        private val LOADER_ADMIN_RECEIVER = ComponentName(
            "com.osamaalek.kiosklauncher",
            "com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver",
        )
    }
}
