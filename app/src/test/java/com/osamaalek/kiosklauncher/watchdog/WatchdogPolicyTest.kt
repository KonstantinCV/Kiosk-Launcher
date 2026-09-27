package com.osamaalek.kiosklauncher.watchdog

import com.osamaalek.kiosklauncher.watchdog.WatchdogPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class WatchdogPolicyTest {

    private val target = "com.example.headjack"
    private val home = "com.oculus.vrshell"
    private val policy = WatchdogPolicy()

    private fun snapshot(
        now: Long,
        targetPackage: String = target,
        foreground: String? = home,
        targetResumed: Boolean = foreground == targetPackage,
        activityEvents: Int = 0,
        foregroundKnown: Boolean = true,
        enabled: Boolean = true,
        paused: Boolean = false,
        loaderUiVisible: Boolean = false,
        interactive: Boolean = true,
    ) = WatchdogPolicy.Snapshot(
        now = now,
        targetPackage = targetPackage,
        enabled = enabled,
        paused = paused,
        loaderUiVisible = loaderUiVisible,
        interactive = interactive,
        foregroundKnown = foregroundKnown,
        targetResumed = targetResumed,
        foregroundPackage = foreground,
        activityEvents = activityEvents,
        graceMs = 10_000,
        blindIntervalMs = 30_000,
    )

    /** What the service does on each tick: evaluate, and launch when asked to. */
    private fun WatchdogPolicy.tick(s: WatchdogPolicy.Snapshot) =
        evaluate(s).also { if (it == Decision.LAUNCH) onLaunched(s) }

    /** When it launched, from decisions by time. */
    private fun Map<Long, Decision>.launches() = filterValues { it == Decision.LAUNCH }.keys.toList()

    @Test
    fun `launches after boot once the grace period has passed`() {
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 0, foreground = null)))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 9_999, foreground = null)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 10_000, foreground = null)))
    }

    @Test
    fun `stays idle while the target is in the foreground`() {
        repeat(10) { i ->
            assertEquals(Decision.IDLE, policy.tick(snapshot(now = i * 5_000L, foreground = target)))
        }
    }

    @Test
    fun `stays idle while the target is resumed next to another app`() {
        repeat(10) { i ->
            val s = snapshot(now = i * 5_000L, foreground = home, targetResumed = true)
            assertEquals(Decision.IDLE, policy.tick(s))
        }
    }

    @Test
    fun `relaunches after the target exits or crashes`() {
        policy.tick(snapshot(now = 0, foreground = target))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 1_000, foreground = home)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 11_000, foreground = home)))
    }

    @Test
    fun `briefly leaving the target does not relaunch it`() {
        policy.tick(snapshot(now = 0, foreground = home))
        policy.tick(snapshot(now = 5_000, foreground = target))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 12_000, foreground = home)))
    }

    @Test
    fun `waits a full grace period between launch attempts`() {
        policy.tick(snapshot(now = 0))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 10_000)))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 15_000)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 20_000)))
    }

    @Test
    fun `does nothing while asleep, disabled, paused, in the loader UI or without a target`() {
        val blocked = listOf(
            snapshot(now = 0, interactive = false),
            snapshot(now = 0, enabled = false),
            snapshot(now = 0, paused = true),
            snapshot(now = 0, loaderUiVisible = true),
            snapshot(now = 0, targetPackage = ""),
        )
        blocked.forEach { assertEquals(Decision.IDLE, WatchdogPolicy().evaluate(it)) }
    }

    @Test
    fun `waking up restarts the grace period`() {
        policy.tick(snapshot(now = 0))
        policy.tick(snapshot(now = 8_000, interactive = false))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 9_000)))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 18_000)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 19_000)))
    }

    @Test
    fun `leaving the loader UI restarts the grace period`() {
        policy.tick(snapshot(now = 0, loaderUiVisible = true))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 60_000)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 70_000)))
    }

    @Test
    fun `without usage access the target is brought forward on the blind interval`() {
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 0, foregroundKnown = false, foreground = null)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 10_000, foregroundKnown = false, foreground = null)))
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 30_000, foregroundKnown = false, foreground = null)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 40_000, foregroundKnown = false, foreground = null)))
    }

    @Test
    fun `a launch into an unknown foreground that nothing follows means the target was already in front`() {
        // Resumed before the events the tracker reads, so nothing is known to be resumed
        val quiet = { now: Long -> snapshot(now = now, foreground = null, activityEvents = 7) }
        assertEquals(Decision.WAIT, policy.tick(quiet(0)))
        assertEquals(Decision.LAUNCH, policy.tick(quiet(10_000)))
        assertEquals(Decision.WAIT, policy.tick(quiet(19_999)))
        assertEquals(Decision.IDLE, policy.tick(quiet(20_000)))
        assertEquals(Decision.IDLE, policy.tick(quiet(600_000)))
        // Events tell again once there are some: here the target has gone and home is in front
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 602_000, activityEvents = 9)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 612_000, activityEvents = 9)))
    }

    @Test
    fun `a launch over a known other app that nothing follows is retried`() {
        // Blocked from starting in the background, say: no event, and home stays in front
        policy.tick(snapshot(now = 0, activityEvents = 7))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 10_000, activityEvents = 7)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 20_000, activityEvents = 7)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 30_000, activityEvents = 7)))
    }

    @Test
    fun `a launch into an unknown foreground followed by events is retried`() {
        policy.tick(snapshot(now = 0, foreground = null, activityEvents = 7))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 10_000, foreground = null, activityEvents = 7)))
        // The target came up and died again, and nothing else resumed
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 12_000, foreground = null, activityEvents = 9)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 20_000, foreground = null, activityEvents = 9)))
    }

    @Test
    fun `a quiet launch says nothing about a new target`() {
        policy.tick(snapshot(now = 0, foreground = null))
        policy.tick(snapshot(now = 10_000, foreground = null))
        assertEquals(Decision.IDLE, policy.tick(snapshot(now = 20_000, foreground = null)))
        val other = "com.example.other"
        assertEquals(Decision.WAIT, policy.tick(snapshot(now = 22_000, targetPackage = other, foreground = null)))
        assertEquals(Decision.LAUNCH, policy.tick(snapshot(now = 32_000, targetPackage = other, foreground = null)))
    }

    @Test
    fun `a throttled launch is made as soon as the cooldown ends`() {
        val policy = WatchdogPolicy(LaunchBackoff(maxLaunches = 2, windowMs = 60_000, cooldownMs = 15_000))
        val decisions = (0..55_000L step 1_000).associateWith { policy.tick(snapshot(now = it)) }
        assertEquals(Decision.THROTTLED, decisions[30_000])
        // Not a grace period after the refusal (40 000), and not 60 000 after that
        assertEquals(listOf(10_000L, 20_000L, 35_000L, 50_000L), decisions.launches())
    }

    @Test
    fun `a launch that was not made costs nothing`() {
        policy.tick(snapshot(now = 0))
        // Target not installed: the service can't launch, so it doesn't report a launch
        for (now in 10_000L..600_000L step 2_000) {
            assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = now)))
        }
        // Installed: launched on the next tick, and the whole crash-loop budget is still there
        val decisions = (602_000L..660_000L step 2_000).associateWith { policy.tick(snapshot(now = it)) }
        assertEquals(listOf(602_000L, 612_000L, 622_000L, 632_000L, 642_000L), decisions.launches())
        assertEquals(Decision.THROTTLED, decisions[652_000])
    }

    @Test
    fun `blind launches do not use up the crash-loop budget`() {
        val blind = (0..900_000L step 2_000).map {
            policy.tick(snapshot(now = it, foregroundKnown = false, foreground = null))
        }
        // At 10 s, then every 30 s
        assertEquals(30, blind.count { it == Decision.LAUNCH })
        assertFalse(Decision.THROTTLED in blind)
        // Usage access back, home in front: five launches before the backoff steps in
        val decisions = (902_000L..960_000L step 2_000).associateWith { policy.tick(snapshot(now = it)) }
        assertEquals(listOf(902_000L, 912_000L, 922_000L, 932_000L, 942_000L), decisions.launches())
    }
}
