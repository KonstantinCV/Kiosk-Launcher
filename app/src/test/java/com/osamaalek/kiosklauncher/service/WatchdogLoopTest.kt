package com.osamaalek.kiosklauncher.service

import android.app.usage.UsageEvents.Event.ACTIVITY_PAUSED
import android.app.usage.UsageEvents.Event.ACTIVITY_RESUMED
import android.app.usage.UsageEvents.Event.ACTIVITY_STOPPED
import com.osamaalek.kiosklauncher.watchdog.DialogWait
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
        val dialogWait = DialogWait()

        /** Horizon OS holds launches up with its "controllers required" dialog. */
        var controllersAsleep = false

        /** Guardian is in front: no launch gets through, and none brings up anything. */
        var guardianUp = false

        fun record(type: Int, packageName: String, at: Long = wall, className: String = "Main") {
            events += ForegroundTracker.Event(at, type, packageName, className)
        }

        fun showLaunchCheck() = record(ACTIVITY_RESUMED, home, className = LAUNCH_CHECK)

        /** The dialog closes: a controller was picked up (the target starts) or it was cancelled. */
        fun closeLaunchCheck(targetStarts: Boolean) {
            record(ACTIVITY_PAUSED, home, className = LAUNCH_CHECK)
            if (targetStarts) resume(target) else resume(home)
        }

        fun showGuardian() {
            record(ACTIVITY_RESUMED, GUARDIAN, className = GUARDIAN_DIALOG)
            guardianUp = true
        }

        /** Guardian goes away by itself; as seen on a Quest, sometimes without a pause or stop. */
        fun hideGuardian(recorded: Boolean) {
            if (recorded) record(ACTIVITY_STOPPED, GUARDIAN, className = GUARDIAN_DIALOG)
            guardianUp = false
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
                    // As WatchdogService does
                    targetResumed = tracker.isResumed(target) || dialogWait.holding(elapsed, tracker.isDialogInFront()),
                    foregroundPackage = tracker.foregroundPackage,
                    activityEvents = tracker.activityEvents,
                    graceMs = 10_000,
                    blindIntervalMs = 30_000,
                    launchesHeldUp = tracker.isGuardianInFront(),
                )
                if (policy.evaluate(s) != Decision.LAUNCH) continue
                policy.onLaunched(s)
                launches += elapsed
                // A launch of an app that is already in front changes nothing, so records nothing
                when {
                    guardianUp -> {}
                    controllersAsleep -> showLaunchCheck()
                    top != target -> resume(target)
                }
                onLaunch()
            }
            return launches
        }
    }

    @Test
    fun `a launch held up by the controllers-required dialog is not repeated for a minute while it is open`() {
        val loop = Loop()
        loop.resume(home)
        loop.controllersAsleep = true

        // One launch, which brings up the dialog; then nothing while it stays open
        assertEquals(1, loop.run(50_000).size)

        // A controller is picked up: the target starts, and is left alone
        loop.controllersAsleep = false
        loop.closeLaunchCheck(targetStarts = true)
        assertEquals(emptyList<Long>(), loop.run(MINUTE))
    }

    @Test
    fun `a controllers-required dialog left open stops holding the watchdog back after a minute`() {
        val loop = Loop()
        loop.resume(home)
        loop.controllersAsleep = true
        val start = loop.elapsed
        val launches = loop.run(5 * MINUTE).map { it - start }

        // Launch 1 at 12 s brings up the dialog, seen at 14 s; the wait ends a minute later, at
        // 74 s. Then a launch every grace period under the crash-loop guard: 5 in 3 minutes, then
        // one a minute, and more once the first ones are 3 minutes old
        assertEquals(
            listOf(12_000L, 84_000L, 94_000L, 104_000L, 114_000L, 174_000L, 234_000L, 276_000L, 286_000L, 296_000L),
            launches,
        )
    }

    @Test
    fun `a dialog whose closing was never recorded does not keep the target from coming back`() {
        val loop = Loop()
        loop.resume(home)
        loop.controllersAsleep = true
        assertEquals(1, loop.run(20_000).size)

        // The dialog goes without a pause; the home resumes
        loop.controllersAsleep = false
        loop.record(ACTIVITY_RESUMED, home)
        val launches = loop.run(30_000)
        assertEquals(1, launches.size)
        assertEquals(target, loop.top)
    }

    @Test
    fun `a cancelled controllers-required dialog gets the target launched again after the grace period`() {
        val loop = Loop()
        loop.resume(home)
        loop.controllersAsleep = true
        assertEquals(1, loop.run(20_000).size)

        loop.controllersAsleep = false
        loop.closeLaunchCheck(targetStarts = false)
        val launches = loop.run(30_000)
        assertEquals(1, launches.size)
    }

    @Test
    fun `launches Guardian holds up are retried and don't use up the crash-loop guard`() {
        for (recorded in listOf(true, false)) {
            val loop = Loop()
            loop.resume(home)
            loop.showGuardian()

            // A launch every grace period for three minutes, from 12 s on: none gets through, none
            // is throttled
            assertEquals(17, loop.run(3 * MINUTE).size)

            // Guardian goes away: the next launch brings the target up, within a grace period
            loop.hideGuardian(recorded)
            assertEquals(1, loop.run(14_000).size)
            assertEquals(target, loop.top)

            // And a crash right after is answered as usual
            loop.crash()
            loop.resume(home)
            assertEquals(1, loop.run(14_000).size)
            assertEquals(target, loop.top)
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
        const val LAUNCH_CHECK = "com.oculus.vrshell.systemdialog.launchcheck.LaunchCheckControllerRequiredDialogActivity"
        const val GUARDIAN = "com.oculus.guardian"
        const val GUARDIAN_DIALOG = "com.oculus.vrguardianservice.guardiandialog.GuardianDialogActivity"
        const val HOUR = 60 * MINUTE
    }
}
