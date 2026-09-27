package com.osamaalek.kiosklauncher.util

import android.app.Application
import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

@RunWith(RobolectricTestRunner::class)
class TargetLauncherTest {

    private val context: Application = RuntimeEnvironment.getApplication()

    private val flat = "com.example.flat"
    private val vr = "com.example.vr"

    @Test
    fun `launch intent of a regular app opens its launcher activity`() {
        val component = TestApps.installLauncherApp(context, flat)

        val intent = checkNotNull(TargetLauncher.launchIntent(context, flat)) { "no launch intent" }
        assertEquals(component, intent.component)
        assertEquals(Intent.ACTION_MAIN, intent.action)
        assertTrue(intent.hasCategory(Intent.CATEGORY_LAUNCHER))
    }

    @Test
    fun `launch intent of a VR app without a launcher entry falls back to the VR category`() {
        val component = TestApps.installVrOnlyApp(context, vr)

        val intent = checkNotNull(TargetLauncher.launchIntent(context, vr)) { "no launch intent" }
        assertEquals(component, intent.component)
        assertEquals(Intent.ACTION_MAIN, intent.action)
        assertTrue(intent.hasCategory(TargetLauncher.CATEGORY_VR))
    }

    @Test
    fun `the launcher entry wins over the VR category`() {
        TestApps.installVrOnlyApp(context, vr, "$vr.VrActivity")
        val launcher = TestApps.installLauncherApp(context, vr, "$vr.MainActivity")

        assertEquals(launcher, TargetLauncher.launchIntent(context, vr)?.component)
    }

    @Test
    fun `there is no launch intent for a missing or unlaunchable app`() {
        TestApps.installAppWithoutLaunchableActivity(context, "com.example.service")

        assertNull(TargetLauncher.launchIntent(context, "com.example.missing"))
        assertNull(TargetLauncher.launchIntent(context, "com.example.service"))
    }

    @Test
    fun `isInstalled means launchable, and never for an empty package`() {
        TestApps.installLauncherApp(context, flat)
        TestApps.installVrOnlyApp(context, vr)
        TestApps.installAppWithoutLaunchableActivity(context, "com.example.service")

        assertTrue(TargetLauncher.isInstalled(context, flat))
        assertTrue(TargetLauncher.isInstalled(context, vr))
        assertFalse(TargetLauncher.isInstalled(context, "com.example.service"))
        assertFalse(TargetLauncher.isInstalled(context, "com.example.missing"))
        assertFalse(TargetLauncher.isInstalled(context, ""))
    }

    @Test
    fun `launch starts a regular app in a new task`() {
        val component = TestApps.installLauncherApp(context, flat)

        assertTrue(TargetLauncher.launch(context, flat))

        val started = checkNotNull(shadowOf(context).nextStartedActivity) { "nothing started" }
        assertEquals(component, started.component)
        assertTrue(started.hasCategory(Intent.CATEGORY_LAUNCHER))
        assertNewTask(started)
    }

    @Test
    fun `launch starts a VR-only app in a new task`() {
        val component = TestApps.installVrOnlyApp(context, vr)

        assertTrue(TargetLauncher.launch(context, vr))

        val started = checkNotNull(shadowOf(context).nextStartedActivity) { "nothing started" }
        assertEquals(component, started.component)
        assertTrue(started.hasCategory(TargetLauncher.CATEGORY_VR))
        assertNewTask(started)
    }

    @Test
    fun `launch of a missing app starts nothing`() {
        assertFalse(TargetLauncher.launch(context, "com.example.missing"))
        assertFalse(TargetLauncher.launch(context, ""))
        assertNull(shadowOf(context).nextStartedActivity)
    }

    private fun assertNewTask(intent: Intent) =
        assertTrue("FLAG_ACTIVITY_NEW_TASK not set", intent.flags and Intent.FLAG_ACTIVITY_NEW_TASK != 0)
}
