package com.osamaalek.kiosklauncher.service

import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.os.SystemClock
import com.osamaalek.kiosklauncher.watchdog.ForegroundState

/**
 * Reads activity events incrementally to know which activities are resumed. Usage events are
 * stamped with the wall clock, so that is what [wallClock] is for; [sinceBoot] only says how far
 * back boot was.
 */
class ForegroundTracker(
    private val source: EventSource,
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val sinceBoot: () -> Long = SystemClock::elapsedRealtime,
) {

    /** A usage event; [type] is one of the UsageEvents.Event types. */
    data class Event(val timestamp: Long, val type: Int, val packageName: String, val className: String)

    fun interface EventSource {
        /** The events stamped in [start, end), oldest first. */
        fun query(start: Long, end: Long): List<Event>
    }

    private val state = ForegroundState()
    private var queriedUntil = 0L
    /** The activity events the last update read that the next one reads again (the overlap). */
    private var overlap = emptySet<Event>()

    /** Counts activity events as they are read, each once despite the overlap. */
    var activityEvents = 0
        private set

    val foregroundPackage: String?
        get() = state.foregroundPackage

    fun isResumed(packageName: String) = state.isResumed(packageName)

    fun update() {
        val now = wallClock()
        // The first time, read everything since boot: the target may have been in front for hours.
        // Afterwards re-read a short overlap: events can be recorded slightly after their timestamp.
        // Replaying them in order yields the same state, so the overlap is harmless.
        var start = if (queriedUntil == 0L) now - sinceBoot() else queriedUntil - OVERLAP_MS
        if (start < now - MAX_LOOKBACK_MS) {
            // Events before that aren't read, so what they left resumed isn't known either
            state.clear()
            start = now - MAX_LOOKBACK_MS
        }
        val readBefore = overlap
        val readAgain = HashSet<Event>()
        // In chunks, so that no single answer (a parcel) gets large
        while (start < now) {
            val end = minOf(start + CHUNK_MS, now)
            for (event in source.query(start, end)) {
                if (!apply(event)) continue
                // Whether it was read before, by what the last update read, not by its timestamp:
                // one recorded late is stamped before that update ran, yet it is new
                if (event !in readBefore) activityEvents++
                if (event.timestamp >= now - OVERLAP_MS) readAgain += event
            }
            start = end
        }
        overlap = readAgain
        queriedUntil = now
    }

    /** Folds [event] into the state; true if it is an activity event. */
    private fun apply(event: Event): Boolean {
        when (event.type) {
            UsageEvents.Event.ACTIVITY_RESUMED -> state.onResumed(event.packageName, event.className)
            // An activity that dies while resumed (crash, force-stop) reports no pause, only
            // DESTROYED, which usage stats store as ACTIVITY_STOPPED
            UsageEvents.Event.ACTIVITY_PAUSED, UsageEvents.Event.ACTIVITY_STOPPED ->
                state.onPaused(event.packageName, event.className)
            // Nothing resumed before a shutdown is still resumed after it, even if no pause was saved
            UsageEvents.Event.DEVICE_SHUTDOWN, UsageEvents.Event.DEVICE_STARTUP -> {
                state.clear()
                return false
            }
            else -> return false
        }
        return true
    }

    companion object {
        private const val OVERLAP_MS = 5_000L
        private const val CHUNK_MS = 60 * 60_000L
        private const val MAX_LOOKBACK_MS = 24 * CHUNK_MS
    }
}

/** Reads the events from UsageStatsManager. */
class UsageEventSource(context: Context) : ForegroundTracker.EventSource {

    private val usageStats = context.getSystemService(UsageStatsManager::class.java)

    override fun query(start: Long, end: Long): List<ForegroundTracker.Event> {
        val events = usageStats.queryEvents(start, end) ?: return emptyList()
        val event = UsageEvents.Event()
        return buildList {
            while (events.hasNextEvent()) {
                events.getNextEvent(event)
                // Device events have no class
                add(ForegroundTracker.Event(
                    event.timeStamp, event.eventType, event.packageName.orEmpty(), event.className.orEmpty()
                ))
            }
        }
    }
}
