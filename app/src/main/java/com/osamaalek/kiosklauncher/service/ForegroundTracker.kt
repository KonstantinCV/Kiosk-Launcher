package com.osamaalek.kiosklauncher.service

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import com.osamaalek.kiosklauncher.watchdog.ForegroundState

/** Reads activity resume/pause events incrementally to know which app is in the foreground. */
class ForegroundTracker(context: Context) {

    private val usageStats = context.getSystemService(UsageStatsManager::class.java)
    private val state = ForegroundState()
    private var queriedUntil = 0L

    fun update(now: Long): String? {
        // Re-read a short overlap each time: events can be recorded slightly after their timestamp.
        // Replaying them in order yields the same state, so the overlap is harmless.
        val start = if (queriedUntil == 0L) now - INITIAL_LOOKBACK_MS else queriedUntil - OVERLAP_MS
        val events = usageStats.queryEvents(start, now) ?: return state.foregroundPackage
        val event = UsageEvents.Event()
        while (events.hasNextEvent()) {
            events.getNextEvent(event)
            when (event.eventType) {
                UsageEvents.Event.ACTIVITY_RESUMED -> state.onResumed(event.packageName)
                UsageEvents.Event.ACTIVITY_PAUSED -> state.onPaused(event.packageName)
            }
        }
        queriedUntil = now
        return state.foregroundPackage
    }

    companion object {
        private const val INITIAL_LOOKBACK_MS = 10 * 60_000L
        private const val OVERLAP_MS = 5_000L
    }
}
