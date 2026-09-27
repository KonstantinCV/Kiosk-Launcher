package com.osamaalek.kiosklauncher.watchdog

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LaunchBackoffTest {

    private val backoff = LaunchBackoff(maxLaunches = 3, windowMs = 60_000, cooldownMs = 20_000)

    @Test
    fun `allows launches up to the limit`() {
        assertTrue(backoff.tryAcquire(0))
        assertTrue(backoff.tryAcquire(10_000))
        assertTrue(backoff.tryAcquire(20_000))
    }

    @Test
    fun `throttles a crash loop to one launch per cooldown`() {
        backoff.tryAcquire(0)
        backoff.tryAcquire(10_000)
        backoff.tryAcquire(20_000)
        assertFalse(backoff.tryAcquire(30_000))
        assertTrue(backoff.tryAcquire(40_000))
        assertFalse(backoff.tryAcquire(50_000))
    }

    @Test
    fun `recovers once launches fall out of the window`() {
        backoff.tryAcquire(0)
        backoff.tryAcquire(10_000)
        backoff.tryAcquire(20_000)
        assertTrue(backoff.tryAcquire(90_000))
        assertTrue(backoff.tryAcquire(91_000))
    }
}
