package com.osamaalek.kiosklauncher.util

import android.content.Context
import com.osamaalek.kiosklauncher.BuildConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class LoaderConfigTest {

    private val context: Context = RuntimeEnvironment.getApplication()
    private val config = LoaderConfig(context)

    @Test
    fun `defaults to enabled, a 10 s grace period, not paused and the build-time target`() {
        assertTrue(config.enabled)
        assertEquals(10, config.graceSeconds)
        assertEquals(0L, config.pausedUntil)
        assertFalse(config.isPaused())
        assertEquals(BuildConfig.DEFAULT_TARGET_PACKAGE, config.targetPackage)
    }

    @Test
    fun `clamps the grace period to 3 to 300 seconds`() {
        val stored = listOf(-5, 0, 2, 3, 45, 300, 301, Int.MAX_VALUE).associateWith {
            config.graceSeconds = it
            config.graceSeconds
        }
        assertEquals(
            mapOf(-5 to 3, 0 to 3, 2 to 3, 3 to 3, 45 to 45, 300 to 300, 301 to 300, Int.MAX_VALUE to 300),
            stored,
        )
    }

    @Test
    fun `trims the target package`() {
        config.targetPackage = "  com.example.headjack \n"
        assertEquals("com.example.headjack", config.targetPackage)
    }

    @Test
    fun `is paused until the pause ends`() {
        config.pausedUntil = 1_000
        assertTrue(config.isPaused(now = 0))
        assertTrue(config.isPaused(now = 999))
        assertFalse(config.isPaused(now = 1_000))
        assertFalse(config.isPaused(now = 5_000))
    }

    @Test
    fun `settings are shared between instances`() {
        config.targetPackage = "com.example.headjack"
        config.enabled = false
        config.graceSeconds = 42
        config.pausedUntil = 1_234

        val other = LoaderConfig(context)
        assertEquals("com.example.headjack", other.targetPackage)
        assertFalse(other.enabled)
        assertEquals(42, other.graceSeconds)
        assertEquals(1_234L, other.pausedUntil)
    }
}
