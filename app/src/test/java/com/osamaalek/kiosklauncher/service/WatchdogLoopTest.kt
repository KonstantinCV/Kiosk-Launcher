package com.osamaalek.kiosklauncher.service

import android.app.usage.UsageEvents.Event.ACTIVITY_PAUSED
import android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED
import android.app.usage.UsageEvents.Event.ACTIVITY_STOPPED
import com.osamaalek.kiosklauncher.watchdog.WatchdogPolicy
import com.osamaalek.kiosklauncher.watchdog.WatchdogPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The tracker and the policy ticked together the way WatchdogService does, against a simulated
 * device that records usage events like Android: which launches happen, and when.
 */
class WatchdogLoopTest {

    private val target = "com.example.headjack"
    private val home = "com.oculus.vrshell"

    private inner class Loop(sinceBoot: Long = 30 * HOUR) {
        var elapsed = sinceBoot
        var wall = 1_700_000_000_000L
        val events = mutableListOf<ForegroundTracker.Event>()
        /** The app that is really in front. */
        var top: String? = null
        /** Things that happen at a given (elapsed) time, before that tick's check. */
        val scheduled = mutableMapOf<Long, () -> Unit>()
        val tracker = ForegroundTracker(
            { start, end -> events.filter { it.timestamp in start until end } },
            wallClock = { wall },
            sinceBoot = { elapsed },
        )
        val policy = WatchdogPolicy()

        fun record(type: Int, packageName: String, at: Long = wall) {
            events += ForegroundTracker.Event(at, type, packageName, "Main")
        }

        fun resume(packageName: String) {
            top?.let { record(ACTIVITY_PAUSED, it) }
            record(ACTIVITY_RESUMED, packageName)
            top?.let { record(ACTIVITY_STOPPED, it) }
            top = packageName
        }

        /** The target's process dies: no pause, only a stop. */
        fun crash() {
            record(ACTIVITY_STOPPED, target)
            top = null
        }

        /** Ticks every 2 s for [ms]; [onLaunch] runs after each launch. Returns when it launched. */
        fun run(ms: Long, onLaunch: () -> Unit = {}): List<Long> {
            val launches = mutableListOf<Long>()
            val end = elapsed + ms
            while (elapsed < end) {
                elapsed += 2_000
                wall += 2_000
                scheduled.remove(elapsed)?.invoke()
                tracker.update()
                val s = WatchdogPolicy.Snapshot(
                    now = elapsed,
                    targetPackage = target,
                    enabled = true,
                    paused = false,
                    loaderUiVisible = false,
                    interactive = true,
                    foregroundKnown = true,
                    targetResumed = tracker.isResumed(target),
                    foregroundPackage = tracker.foregroundPackage,
                    activityEvents = tracker.activityEvents,
                    graceMs = 10_000,
                    blindIntervalMs = 30_000,
                )
                if (policy.evaluate(s) != Decision.LAUNCH) continue
                policy.onLaunched(s)
                launches += elapsed
                // A launch of an app that is already in front changes nothing, so records nothing
                if (top != target) resume(target)
                onLaunch()
            }
            return launches
        }
    }

    @Test
    fun `a target in front for hours is seen by a new watchdog`() {
        val loop = Loop()
        loop.record(ACTIVITY_RESUMED, target, at = loop.wall - 3 * HOUR)
        loop.top = target
        assertEquals(emptyList<Long>(), loop.run(10 * MINUTE))
    }

    @Test
    fun `a target in front since before the lookback is launched once, not every grace period`() {
        val loop = Loop()
        loop.record(ACTIVITY_RESUMED, target, at = loop.wall - 25 * HOUR)
        loop.top = target
        assertEquals(1, loop.run(10 * MINUTE).size)
    }

    @Test
    fun `a crash is answered although nothing else resumes`() {
        val loop = Loop()
        loop.resume(target)
        loop.scheduled[loop.elapsed + 20_000] = loop::crash
        assertEquals(1, loop.run(10 * MINUTE).size)
        assertEquals(target, loop.top)
    }

    @Test
    fun `a menu over the target does not get it relaunched`() {
        val loop = Loop()
        loop.resume(target)
        // The target stays resumed under it
        loop.scheduled[loop.elapsed + 10_000] = { loop.record(ACTIVITY_RESUMED, home) }
        loop.scheduled[loop.elapsed + 40_000] = { loop.record(ACTIVITY_PAUSED, home) }
        assertEquals(emptyList<Long>(), loop.run(10 * MINUTE))
    }

    @Test
    fun `a wall-clock jump changes nothing in grace and backoff timing`() {
        /** The target crashes 4 s after every launch and home comes back; the clock may jump back an hour. */
        fun crashLoop(jumpBackAt: Set<Long>): List<Long> {
            val loop = Loop()
            loop.resume(home)
            val start = loop.elapsed
            for (at in jumpBackAt) loop.scheduled[start + at] = { loop.wall -= HOUR }
            return loop.run(3 * MINUTE + 30_000) {
                loop.scheduled[loop.elapsed + 4_000] = {
                    loop.crash()
                    loop.resume(home)
                }
            }.map { it - start }
        }

        val steady = crashLoop(emptySet())
        // A grace period after each crash is seen (a tick after it), five times; then one a minute
        assertEquals(listOf(12_000L, 28_000L, 44_000L, 60_000L, 76_000L, 136_000L, 196_000L), steady)
        // Once within a grace period and once within the cooldown, both while no event is due
        assertEquals(steady, crashLoop(setOf(steady[1] + 8_000, steady[4] + 20_000)))
    }

    private companion object {
        const val MINUTE = 60_000L
        const val HOUR = 60 * MINUTE
    }
}
