package com.osamaalek.kiosklauncher.util

import android.content.Context
import com.osamaalek.kiosklauncher.BuildConfig

/** Loader settings, shared by the UI, the watchdog service and the adb command receiver. */
class LoaderConfig(context: Context) {

    private val prefs = context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    var targetPackage: String
        get() = prefs.getString(KEY_TARGET, null) ?: BuildConfig.DEFAULT_TARGET_PACKAGE
        set(value) = prefs.edit().putString(KEY_TARGET, value.trim()).apply()

    var enabled: Boolean
        get() = prefs.getBoolean(KEY_ENABLED, true)
        set(value) = prefs.edit().putBoolean(KEY_ENABLED, value).apply()

    var graceSeconds: Int
        get() = prefs.getInt(KEY_GRACE, DEFAULT_GRACE_SECONDS)
        set(value) = prefs.edit().putInt(KEY_GRACE, value.coerceIn(MIN_GRACE_SECONDS, MAX_GRACE_SECONDS)).apply()

    var pausedUntil: Long
        get() = prefs.getLong(KEY_PAUSED_UNTIL, 0L)
        set(value) = prefs.edit().putLong(KEY_PAUSED_UNTIL, value).apply()

    fun isPaused(now: Long = System.currentTimeMillis()) = pausedUntil > now

    companion object {
        private const val PREFS_NAME = "loader"
        private const val KEY_TARGET = "target_package"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_GRACE = "grace_seconds"
        private const val KEY_PAUSED_UNTIL = "paused_until"

        const val DEFAULT_GRACE_SECONDS = 10
        const val MIN_GRACE_SECONDS = 3
        const val MAX_GRACE_SECONDS = 300
    }
}
