package com.osamaalek.kiosklauncher.watchdog

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LaunchBackoffTest {

    private val backoff = LaunchBackoff(maxLaunches = 3, windowMs = 60_000, cooldownMs = 20_000)

    /** Launches if allowed, like the watchdog does. */
    private fun tryLaunch(now: Long) = backoff.canLaunch(now).also { if (it) backoff.onLaunched(now) }

    @Test
    fun `allows launches up to the limit`() {
        assertTrue(tryLaunch(0))
        assertTrue(tryLaunch(10_000))
        assertTrue(tryLaunch(20_000))
    }

    @Test
    fun `throttles a crash loop to one launch per cooldown`() {
        tryLaunch(0)
        tryLaunch(10_000)
        tryLaunch(20_000)
        assertFalse(tryLaunch(30_000))
        assertTrue(tryLaunch(40_000))
        assertFalse(tryLaunch(50_000))
    }

    @Test
    fun `recovers once launches fall out of the window`() {
        tryLaunch(0)
        tryLaunch(10_000)
        tryLaunch(20_000)
        assertTrue(tryLaunch(90_000))
        assertTrue(tryLaunch(91_000))
    }

    @Test
    fun `asking is not launching`() {
        repeat(10) { assertTrue(backoff.canLaunch(it * 1_000L)) }
        assertTrue(tryLaunch(10_000))
        assertTrue(tryLaunch(11_000))
        assertTrue(tryLaunch(12_000))
    }
}
