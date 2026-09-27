package com.osamaalek.kiosklauncher.watchdog

import com.osamaalek.kiosklauncher.watchdog.WatchdogPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

class WatchdogPolicyTest {

    private val target = "com.example.headjack"
    private val home = "com.oculus.vrshell"
    private val policy = WatchdogPolicy()

    private fun snapshot(
        now: Long,
        foreground: String? = home,
        foregroundKnown: Boolean = true,
        enabled: Boolean = true,
        paused: Boolean = false,
        loaderUiVisible: Boolean = false,
        interactive: Boolean = true,
        targetPackage: String = target,
    ) = WatchdogPolicy.Snapshot(
        now = now,
        targetPackage = targetPackage,
        enabled = enabled,
        paused = paused,
        loaderUiVisible = loaderUiVisible,
        interactive = interactive,
        foregroundKnown = foregroundKnown,
        foregroundPackage = foreground,
        graceMs = 10_000,
        blindIntervalMs = 30_000,
    )

    @Test
    fun `launches after boot once the grace period has passed`() {
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 0, foreground = null)))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 9_999, foreground = null)))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 10_000, foreground = null)))
    }

    @Test
    fun `stays idle while the target is in the foreground`() {
        repeat(10) { i ->
            assertEquals(Decision.IDLE, policy.evaluate(snapshot(now = i * 5_000L, foreground = target)))
        }
    }

    @Test
    fun `relaunches after the target exits or crashes`() {
        policy.evaluate(snapshot(now = 0, foreground = target))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 1_000, foreground = home)))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 11_000, foreground = home)))
    }

    @Test
    fun `briefly leaving the target does not relaunch it`() {
        policy.evaluate(snapshot(now = 0, foreground = home))
        policy.evaluate(snapshot(now = 5_000, foreground = target))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 12_000, foreground = home)))
    }

    @Test
    fun `waits a full grace period between launch attempts`() {
        policy.evaluate(snapshot(now = 0))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 10_000)))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 15_000)))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 20_000)))
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
        policy.evaluate(snapshot(now = 0))
        policy.evaluate(snapshot(now = 8_000, interactive = false))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 9_000)))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 18_000)))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 19_000)))
    }

    @Test
    fun `leaving the loader UI restarts the grace period`() {
        policy.evaluate(snapshot(now = 0, loaderUiVisible = true))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 60_000)))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 70_000)))
    }

    @Test
    fun `without usage access the target is brought forward on the blind interval`() {
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 0, foregroundKnown = false, foreground = null)))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 10_000, foregroundKnown = false, foreground = null)))
        assertEquals(Decision.WAIT, policy.evaluate(snapshot(now = 30_000, foregroundKnown = false, foreground = null)))
        assertEquals(Decision.LAUNCH, policy.evaluate(snapshot(now = 40_000, foregroundKnown = false, foreground = null)))
    }
}
