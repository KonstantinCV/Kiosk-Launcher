package com.osamaalek.kiosklauncher.service

import android.app.usage.UsageEvents.Event.ACTIVITY_PAUSED
import android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED
import android.app.usage.UsageEvents.Event.ACTIVITY_STOPPED
import android.app.usage.UsageEvents.Event.DEVICE_SHUTDOWN
import android.app.usage.UsageEvents.Event.DEVICE_STARTUP
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundTrackerTest {

    private val target = "com.example.headjack"
    private val home = "com.oculus.vrshell"

    private var wall = 1_700_000_000_000L
    private var elapsed = HOUR
    private val boot get() = wall - elapsed
    private val events = mutableListOf<ForegroundTracker.Event>()
    private val queries = mutableListOf<Pair<Long, Long>>()
    private val tracker = ForegroundTracker(
        source = { start, end ->
            queries += start to end
            events.filter { it.timestamp in start until end }
        },
        wallClock = { wall },
        sinceBoot = { elapsed },
    )

    private fun event(type: Int, packageName: String, className: String = "Main", at: Long = wall) {
        events += ForegroundTracker.Event(at, type, packageName, className)
    }

    /** The next tick, a second later: a query ends before "now", so this reads what just happened. */
    private fun update() {
        wall += 1_000
        elapsed += 1_000
        tracker.update()
    }

    @Test
    fun `sees Horizon OS's controllers-required launch check while it is open`() {
        val dialog = "com.oculus.vrshell.systemdialog.launchcheck.LaunchCheckControllerRequiredDialogActivity"
        event(ACTIVITY_RESUMED, home, "Home")
        update()
        assertFalse(tracker.isLaunchCheckShowing())

        // The launch is held up: the dialog resumes instead of the target
        event(ACTIVITY_RESUMED, home, dialog)
        update()
        assertTrue(tracker.isLaunchCheckShowing())
        assertFalse(tracker.isResumed(target))

        // A controller is picked up: the dialog goes and the target comes up
        event(ACTIVITY_PAUSED, home, dialog)
        event(ACTIVITY_RESUMED, target)
        update()
        assertFalse(tracker.isLaunchCheckShowing())
        assertTrue(tracker.isResumed(target))
    }

    @Test
    fun `sees the Guardian dialog while it is open`() {
        val guardian = "com.oculus.guardian"
        val dialog = "com.oculus.vrguardianservice.guardiandialog.GuardianDialogActivity"
        event(ACTIVITY_RESUMED, guardian, dialog)
        update()
        assertTrue(tracker.isLaunchCheckShowing())

        event(ACTIVITY_STOPPED, guardian, dialog)
        update()
        assertFalse(tracker.isLaunchCheckShowing())
    }

    @Test
    fun `other Guardian activities don't hold launches up`() {
        event(ACTIVITY_RESUMED, "com.oculus.guardian", "com.oculus.vrguardianservice.SomethingElse")
        update()
        assertFalse(tracker.isLaunchCheckShowing())
    }

    @Test
    fun `sees Android's USB debugging prompt while it is open`() {
        val systemUi = "com.android.systemui"
        val prompt = "com.android.systemui.usb.UsbDebuggingActivity"
        event(ACTIVITY_RESUMED, systemUi, prompt)
        update()
        assertTrue(tracker.isLaunchCheckShowing())

        event(ACTIVITY_PAUSED, systemUi, prompt)
        update()
        assertFalse(tracker.isLaunchCheckShowing())
    }

    @Test
    fun `other System UI activities don't hold launches up`() {
        event(ACTIVITY_RESUMED, "com.android.systemui", "com.android.systemui.recents.RecentsActivity")
        update()
        assertFalse(tracker.isLaunchCheckShowing())
    }

    @Test
    fun `the home and other shell screens are not a launch check`() {
        event(ACTIVITY_RESUMED, home, "com.oculus.vrshell.HomeActivity")
        event(ACTIVITY_RESUMED, "com.example.other", "com.oculus.vrshell.systemdialog.launchcheck.Fake")
        update()
        assertFalse(tracker.isLaunchCheckShowing())
    }

    @Test
    fun `a normal exit to home`() {
        event(ACTIVITY_RESUMED, target)
        update()
        assertTrue(tracker.isResumed(target))
        event(ACTIVITY_PAUSED, target)
        event(ACTIVITY_RESUMED, home, "Home")
        event(ACTIVITY_STOPPED, target)
        update()
        assertFalse(tracker.isResumed(target))
        assertEquals(home, tracker.foregroundPackage)
    }

    @Test
    fun `a crash is seen even if nothing else resumes`() {
        event(ACTIVITY_RESUMED, target, "A")
        update()
        // A process that dies reports no pause, only DESTROYED, which is stored as STOPPED
        event(ACTIVITY_STOPPED, target, "A")
        update()
        assertFalse(tracker.isResumed(target))
        assertNull(tracker.foregroundPackage)
    }

    @Test
    fun `an activity that finishes and starts another keeps the target up`() {
        event(ACTIVITY_RESUMED, target, "A")
        event(ACTIVITY_PAUSED, target, "A")
        event(ACTIVITY_RESUMED, target, "B")
        event(ACTIVITY_STOPPED, target, "A")
        update()
        assertTrue(tracker.isResumed(target))
    }

    @Test
    fun `an overlay that comes and goes keeps the target up`() {
        event(ACTIVITY_RESUMED, target)
        event(ACTIVITY_RESUMED, home, "Menu")
        update()
        assertTrue(tracker.isResumed(target))
        assertEquals(home, tracker.foregroundPackage)
        event(ACTIVITY_PAUSED, home, "Menu")
        update()
        assertTrue(tracker.isResumed(target))
        assertEquals(target, tracker.foregroundPackage)
    }

    @Test
    fun `an activity resumed before its sibling paused keeps the target up`() {
        event(ACTIVITY_RESUMED, target, "A")
        event(ACTIVITY_RESUMED, target, "B")
        event(ACTIVITY_PAUSED, target, "A")
        update()
        assertTrue(tracker.isResumed(target))
    }

    @Test
    fun `a device shutdown or startup ends every resumed activity`() {
        // On boot usage stats add both, after the events saved before it (maybe a resume, no pause)
        for (type in listOf(DEVICE_SHUTDOWN, DEVICE_STARTUP)) {
            event(ACTIVITY_RESUMED, target)
            event(ACTIVITY_RESUMED, home, "Home")
            event(type, "android", "")
            update()
            assertFalse(tracker.isResumed(target))
            assertNull(tracker.foregroundPackage)
        }
    }

    @Test
    fun `the first update reads everything since boot, an hour at a time`() {
        elapsed = 5 * HOUR + 30 * 60_000L
        event(ACTIVITY_RESUMED, target, at = boot + 60_000)
        update()
        assertTrue(tracker.isResumed(target))
        assertEquals(6, queries.size)
        assertEquals(boot, queries.first().first)
        assertEquals(wall, queries.last().second)
        assertTrue(queries.all { (start, end) -> end - start <= HOUR })
        assertTrue(queries.zipWithNext().all { (a, b) -> a.second == b.first })

        // Afterwards only what is new, plus a few seconds of overlap
        queries.clear()
        update()
        assertEquals(listOf(wall - 6_000 to wall), queries)
    }

    @Test
    fun `the first update looks back a day at most`() {
        elapsed = 30 * 24 * HOUR
        event(ACTIVITY_RESUMED, target, at = wall - 25 * HOUR)
        update()
        assertFalse(tracker.isResumed(target))
        assertEquals(24, queries.size)
        assertEquals(wall - 24 * HOUR, queries.first().first)
    }

    @Test
    fun `after a gap of more than a day nothing from before it is trusted`() {
        event(ACTIVITY_RESUMED, target)
        update()
        // Asleep: no tick ran for a while, and the pause happened longer than a day ago
        event(ACTIVITY_PAUSED, target, at = wall + HOUR)
        wall += 30 * HOUR
        elapsed += 30 * HOUR
        update()
        assertFalse(tracker.isResumed(target))
    }

    @Test
    fun `an event recorded late is still read`() {
        event(ACTIVITY_RESUMED, target)
        update()
        // Stamped before the last query ended, but only visible after it
        event(ACTIVITY_PAUSED, target, at = wall - 500)
        update()
        assertFalse(tracker.isResumed(target))
    }

    @Test
    fun `an event recorded late is counted, once`() {
        event(ACTIVITY_RESUMED, target)
        update()
        val count = tracker.activityEvents
        // Stamped before the last query ended, but only visible after it: it is still news
        event(ACTIVITY_STOPPED, target, at = wall - 500)
        update()
        assertEquals(count + 1, tracker.activityEvents)
        update()
        assertEquals(count + 1, tracker.activityEvents)
    }

    @Test
    fun `each activity event is counted once, although the overlap reads it again`() {
        event(ACTIVITY_RESUMED, home, "Home")
        update()
        val count = tracker.activityEvents
        repeat(3) { update() }
        assertEquals(count, tracker.activityEvents)
        event(ACTIVITY_PAUSED, home, "Home")
        event(ACTIVITY_RESUMED, target)
        update()
        assertEquals(count + 2, tracker.activityEvents)
    }

    @Test
    fun `reads on after the wall clock goes back`() {
        event(ACTIVITY_RESUMED, home, "Home")
        update()
        wall -= HOUR
        update()
        val count = tracker.activityEvents
        event(ACTIVITY_PAUSED, home, "Home")
        event(ACTIVITY_RESUMED, target)
        update()
        assertTrue(tracker.isResumed(target))
        assertEquals(count + 2, tracker.activityEvents)
    }

    private companion object {
        const val HOUR = 60 * 60_000L
    }
}
