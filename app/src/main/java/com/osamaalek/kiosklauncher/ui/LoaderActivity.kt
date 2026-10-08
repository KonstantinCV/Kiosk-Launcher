package com.osamaalek.kiosklauncher.ui

import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import androidx.appcompat.app.AppCompatActivity

/**
 * Base for the loader's own screens: the watchdog stands down while an operator is using one.
 *
 * Being resumed isn't enough to count as in use. On a Quest a 2D panel stays open and resumed
 * beside the Horizon home and other panels until it is closed, so a loader panel left open after
 * provisioning, or after a quick look, would keep the watchdog idle until the next reboot. And
 * Horizon OS resumes such a panel again by itself, for example when Guardian or an immersive app
 * lets go of the view. So a screen only counts while it is resumed and focused and a person
 * opened or touched it within [IDLE_TIMEOUT_MS]: opening it (onCreate, or onNewIntent when it is
 * already open) or any input counts, being resumed again does not. Short, because on a Quest every
 * panel keeps focus on its own display, so leaving the panel isn't reported: an untouched panel
 * holds the target back for that long after it was last used.
 */
abstract class LoaderActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        lastUsedAt = SystemClock.elapsedRealtime()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        lastUsedAt = SystemClock.elapsedRealtime()
    }

    override fun onResume() {
        super.onResume()
        // A resumed screen is normally the top one too; Android reports it if it isn't
        resumed = true
        topResumed = true
    }

    override fun onTopResumedActivityChanged(isTopResumedActivity: Boolean) {
        super.onTopResumedActivityChanged(isTopResumedActivity)
        topResumed = isTopResumedActivity
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
        const val IDLE_TIMEOUT_MS = 30_000L

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
