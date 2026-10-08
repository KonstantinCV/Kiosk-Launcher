package com.osamaalek.kiosklauncher.ui

import android.os.Bundle
import android.os.SystemClock
import androidx.appcompat.app.AppCompatActivity

/**
 * Base for the loader's own screens: the watchdog stands down while an operator is using one.
 *
 * Being resumed isn't enough to count as in use. On a Quest a 2D panel stays open and resumed
 * beside the Horizon home and other panels until it is closed, so a loader panel left open after
 * provisioning, or after a quick look, would keep the watchdog idle until the next reboot. Horizon
 * OS also resumes, refocuses and even recreates such a panel by itself (after Guardian, after an
 * immersive app), and without a controller the panel never gets the focus at all. So a screen
 * counts as in use only while it is resumed and a person opened or touched it within
 * [IDLE_TIMEOUT_MS]: opening it (a new screen, not one recreated after a configuration change) or
 * any input counts; being resumed, focused or recreated again does not.
 */
abstract class LoaderActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState == null) lastUsedAt = SystemClock.elapsedRealtime()
    }

    override fun onResume() {
        super.onResume()
        resumed = true
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
        /** How long an untouched loader screen keeps the watchdog standing down. */
        const val IDLE_TIMEOUT_MS = 30_000L

        @Volatile
        private var resumed = false

        @Volatile
        private var lastUsedAt = 0L

        /** Whether an operator is using a loader screen right now. */
        val isVisible: Boolean
            get() = resumed && SystemClock.elapsedRealtime() - lastUsedAt < IDLE_TIMEOUT_MS
    }
}
