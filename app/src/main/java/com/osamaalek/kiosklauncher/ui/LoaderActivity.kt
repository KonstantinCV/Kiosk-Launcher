package com.osamaalek.kiosklauncher.ui

import android.os.SystemClock
import androidx.appcompat.app.AppCompatActivity

/**
 * Base for the loader's own screens: the watchdog stands down while an operator is using one.
 *
 * Being resumed isn't enough to count as in use. On a Quest a 2D panel stays open and resumed
 * beside the Horizon home and other panels until it is closed, so a loader panel left open after
 * provisioning, or after a quick look, would keep the watchdog idle until the next reboot. So a
 * screen only counts while it is the top resumed (focused) activity and was touched within
 * [IDLE_TIMEOUT_MS].
 */
abstract class LoaderActivity : AppCompatActivity() {

    override fun onResume() {
        super.onResume()
        // A resumed screen is normally the top one too; Android reports it if it isn't
        resumed = true
        topResumed = true
        lastUsedAt = SystemClock.elapsedRealtime()
    }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        topResumed = isTopResumedActivity
        if (isTopResumedActivity) lastUsedAt = SystemClock.elapsedRealtime()
    }

    override fun onUserInteraction() {
        super.onUserInteraction()
        lastUsedAt = SystemClock.elapsedRealtime()
    }

    override fun onPause() {
        resumed = false
        super.onPause()
    }

    companion object {
        /** How long an untouched, focused loader screen keeps the watchdog standing down. */
        const val IDLE_TIMEOUT_MS = 2 * 60_000L

        @Volatile
        private var resumed = false

        @Volatile
        private var topResumed = false

        @Volatile
        private var lastUsedAt = 0L

        /** Whether an operator is using a loader screen right now. */
        val isVisible: Boolean
            get() = resumed && topResumed && SystemClock.elapsedRealtime() - lastUsedAt < IDLE_TIMEOUT_MS
    }
}
