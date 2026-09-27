package com.osamaalek.kiosklauncher.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.osamaalek.kiosklauncher.util.LoaderConfig
import com.osamaalek.kiosklauncher.util.TargetLauncher

/**
 * Configuration over adb, for provisioning headsets without touching the UI. Only senders
 * holding WRITE_SECURE_SETTINGS (the adb shell) can reach it; see the manifest. Example:
 *
 *   adb shell am broadcast -n com.osamaalek.kiosklauncher/.receiver.AdminCommandReceiver \
 *       -a com.osamaalek.kiosklauncher.action.SET_TARGET --es package com.example.headjackapp
 *
 * The running watchdog picks up changes on its next check.
 */
class AdminCommandReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val config = LoaderConfig(context)
        when (intent.action) {
            ACTION_SET_TARGET -> {
                val pkg = intent.getStringExtra(EXTRA_PACKAGE).orEmpty()
                if (!TargetLauncher.isInstalled(context, pkg)) {
                    fail("No launchable app with package '$pkg'")
                    return
                }
                config.targetPackage = pkg
            }
            ACTION_ENABLE -> config.enabled = true
            ACTION_DISABLE -> config.enabled = false
            ACTION_PAUSE -> {
                val minutes = intent.getIntExtra(EXTRA_MINUTES, DEFAULT_PAUSE_MINUTES)
                config.pausedUntil = System.currentTimeMillis() + minutes * 60_000L
            }
            ACTION_RESUME -> config.pausedUntil = 0L
            ACTION_SET_GRACE -> {
                val seconds = intent.getIntExtra(EXTRA_SECONDS, -1)
                if (seconds < 0) {
                    fail("Missing --ei $EXTRA_SECONDS")
                    return
                }
                config.graceSeconds = seconds
            }
            else -> {
                fail("Unknown action ${intent.action}")
                return
            }
        }
        Log.i(TAG, "${intent.action} applied: target=${config.targetPackage} enabled=${config.enabled} " +
            "grace=${config.graceSeconds}s pausedUntil=${config.pausedUntil}")
        resultCode = RESULT_OK
        resultData = "OK"
    }

    private fun fail(message: String) {
        Log.w(TAG, message)
        resultCode = RESULT_ERROR
        resultData = message
    }

    companion object {
        private const val TAG = "AdminCommandReceiver"
        private const val PREFIX = "com.osamaalek.kiosklauncher.action."

        const val ACTION_SET_TARGET = PREFIX + "SET_TARGET"
        const val ACTION_ENABLE = PREFIX + "ENABLE"
        const val ACTION_DISABLE = PREFIX + "DISABLE"
        const val ACTION_PAUSE = PREFIX + "PAUSE"
        const val ACTION_RESUME = PREFIX + "RESUME"
        const val ACTION_SET_GRACE = PREFIX + "SET_GRACE"

        const val EXTRA_PACKAGE = "package"
        const val EXTRA_MINUTES = "minutes"
        const val EXTRA_SECONDS = "seconds"

        private const val DEFAULT_PAUSE_MINUTES = 30
        private const val RESULT_OK = -1
        private const val RESULT_ERROR = 1
    }
}
