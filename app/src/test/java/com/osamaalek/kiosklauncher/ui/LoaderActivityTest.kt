package com.osamaalek.kiosklauncher.ui

import android.app.Application
import android.content.Intent
import android.os.Looper
import com.osamaalek.kiosklauncher.util.LoaderConfig
import com.osamaalek.kiosklauncher.util.TestApps
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ActivityController
import java.time.Duration

/**
 * The watchdog stands down only while an operator is using a loader screen: focused and touched
 * recently. On a Quest the panel stays resumed beside the home environment after the user leaves
 * it, and that alone must not keep the target from being launched.
 */
@RunWith(RobolectricTestRunner::class)
class LoaderActivityTest {

    private val context: Application = RuntimeEnvironment.getApplication()

    private lateinit var controller: ActivityController<MainActivity>

    @Before
    fun open() {
        // An installed target, so the screen doesn't open the app list
        TestApps.installLauncherApp(context, "com.example.headjack")
        LoaderConfig(context).targetPackage = "com.example.headjack"
        controller = Robolectric.buildActivity(MainActivity::class.java).setup()
    }

    @After
    fun close() {
        controller.pause().stop().destroy()
    }

    private fun advance(duration: Duration) = shadowOf(Looper.getMainLooper()).idleFor(duration)

    @Test
    fun `a screen the operator just opened holds the watchdog back`() {
        assertTrue(LoaderActivity.isVisible)
    }

    @Test
    fun `a screen that lost focus but stays resumed does not`() {
        // The Meta button: the Horizon home takes focus, the loader panel stays open and resumed
        controller.topActivityResumed(false)
        assertFalse(LoaderActivity.isVisible)

        // Back to the panel
        controller.topActivityResumed(true)
        assertTrue(LoaderActivity.isVisible)
    }

    @Test
    fun `a focused screen nobody touches stops holding it back after the idle timeout`() {
        advance(Duration.ofMillis(LoaderActivity.IDLE_TIMEOUT_MS - 1_000))
        assertTrue(LoaderActivity.isVisible)

        advance(Duration.ofSeconds(2))
        assertFalse(LoaderActivity.isVisible)

        // The operator comes back to it
        controller.get().onUserInteraction()
        assertTrue(LoaderActivity.isVisible)
    }

    @Test
    fun `touching the screen keeps holding it back`() {
        repeat(5) {
            advance(Duration.ofMillis(LoaderActivity.IDLE_TIMEOUT_MS / 2))
            controller.get().onUserInteraction()
        }
        assertTrue(LoaderActivity.isVisible)
    }

    @Test
    fun `the system resuming the screen again does not count as use`() {
        // Horizon OS backgrounds the panel (Guardian, an immersive app) and brings it back later
        advance(Duration.ofMillis(LoaderActivity.IDLE_TIMEOUT_MS + 1_000))
        controller.pause()
        controller.topActivityResumed(false)
        controller.resume()
        controller.topActivityResumed(true)
        assertFalse(LoaderActivity.isVisible)
    }

    @Test
    fun `opening the screen again counts as use`() {
        advance(Duration.ofMillis(LoaderActivity.IDLE_TIMEOUT_MS + 1_000))
        assertFalse(LoaderActivity.isVisible)

        // Launched from the app library while still open (singleTask)
        controller.newIntent(Intent(context, MainActivity::class.java))
        assertTrue(LoaderActivity.isVisible)
    }

    @Test
    fun `a paused screen does not`() {
        controller.pause()
        assertFalse(LoaderActivity.isVisible)
        controller.resume()
    }
}
