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
 * `am broadcast` prints the outcome: result=-1, data="OK" when the command was applied, or
 * result=1 and the reason when it was rejected, in which case nothing was changed.
 * The running watchdog picks up changes on its next check.
 */
class AdminCommandReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val config = LoaderConfig(context)
        val error = apply(context, config, intent)
        if (error != null) {
            Log.w(TAG, error)
            resultCode = RESULT_ERROR
            resultData = error
            return
        }
        Log.i(TAG, "${intent.action} applied: target=${config.targetPackage} enabled=${config.enabled} " +
            "grace=${config.graceSeconds}s pausedUntil=${config.pausedUntil}")
        resultCode = RESULT_OK
        resultData = "OK"
    }

    /** Applies the command, or returns why it was rejected without changing anything. */
    private fun apply(context: Context, config: LoaderConfig, intent: Intent): String? {
        when (intent.action) {
            ACTION_SET_TARGET -> {
                // Checked as it will be stored: LoaderConfig trims it
                val pkg = intent.getStringExtra(EXTRA_PACKAGE).orEmpty().trim()
                if (pkg == context.packageName) return "The loader can't be its own target ('$pkg')"
                if (!TargetLauncher.isInstalled(context, pkg)) return "No launchable app with package '$pkg'"
                config.targetPackage = pkg
            }
            ACTION_ENABLE -> config.enabled = true
            ACTION_DISABLE -> config.enabled = false
            ACTION_PAUSE -> {
                val minutes = if (intent.hasExtra(EXTRA_MINUTES)) {
                    intent.intExtra(EXTRA_MINUTES) ?: return "Pass the minutes with --ei, e.g. --ei $EXTRA_MINUTES 30"
                } else {
                    DEFAULT_PAUSE_MINUTES
                }
                if (minutes < 1) return "The pause must be at least 1 minute, got $minutes"
                config.pausedUntil = System.currentTimeMillis() + minutes * 60_000L
            }
            ACTION_RESUME -> config.pausedUntil = 0L
            ACTION_SET_GRACE -> {
                val seconds = intent.intExtra(EXTRA_SECONDS) ?: return "Missing --ei $EXTRA_SECONDS"
                if (seconds !in LoaderConfig.MIN_GRACE_SECONDS..LoaderConfig.MAX_GRACE_SECONDS) {
                    return "The grace period must be ${LoaderConfig.MIN_GRACE_SECONDS} to " +
                        "${LoaderConfig.MAX_GRACE_SECONDS} seconds, got $seconds"
                }
                config.graceSeconds = seconds
            }
            else -> return "Unknown action ${intent.action}"
        }
        return null
    }

    /**
     * The extra [name] if it was sent as an int (--ei), else null: missing, or sent with another
     * type such as --es, for which getIntExtra would quietly return its default.
     */
    @Suppress("DEPRECATION") // Bundle.get: the typed getters can't tell a mistyped extra from a missing one
    private fun Intent.intExtra(name: String): Int? = extras?.get(name) as? Int

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
