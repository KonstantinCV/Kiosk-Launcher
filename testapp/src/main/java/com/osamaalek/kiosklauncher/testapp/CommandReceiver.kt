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
                // Thrown from the next main-thread message rather than here, so adb still gets the
                // broadcast result. Uncaught, it kills the process like any real crash.
                Handler(Looper.getMainLooper()).post { throw RuntimeException("E2E induced crash") }
            }
            ACTION_PROBE_ADMIN -> {
                // This app doesn't hold WRITE_SECURE_SETTINGS, so the system must drop this
                // before it reaches the loader.
                context.sendBroadcast(Intent(LOADER_ACTION_DISABLE).setComponent(LOADER_ADMIN_RECEIVER))
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

    companion object {
        private const val PREFIX = "com.osamaalek.kiosklauncher.testapp.action."

        const val ACTION_EXIT = PREFIX + "EXIT"
        const val ACTION_CRASH = PREFIX + "CRASH"
        const val ACTION_PROBE_ADMIN = PREFIX + "PROBE_ADMIN"

        private const val RESULT_ERROR = 1

        private const val LOADER_ACTION_DISABLE = "com.osamaalek.kiosklauncher.action.DISABLE"
        private val LOADER_ADMIN_RECEIVER = ComponentName(
            "com.osamaalek.kiosklauncher",
            "com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver",
        )
    }
}
