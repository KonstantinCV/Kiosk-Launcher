package com.osamaalek.kiosklauncher.receiver

import android.app.Application
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Looper
import androidx.core.content.ContextCompat
import com.osamaalek.kiosklauncher.BuildConfig
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.ACTION_DISABLE
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.ACTION_ENABLE
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.ACTION_PAUSE
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.ACTION_RESUME
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.ACTION_SET_GRACE
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.ACTION_SET_TARGET
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.EXTRA_MINUTES
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.EXTRA_PACKAGE
import com.osamaalek.kiosklauncher.receiver.AdminCommandReceiver.Companion.EXTRA_SECONDS
import com.osamaalek.kiosklauncher.util.LoaderConfig
import com.osamaalek.kiosklauncher.util.TestApps
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf

/**
 * The adb commands, delivered the way `adb shell am broadcast` delivers them: as an ordered
 * broadcast whose result code and data are printed back to the shell ("Broadcast completed:
 * result=-1, data="OK""). Each command goes to a receiver registered at runtime, so the
 * WRITE_SECURE_SETTINGS guard on the manifest entry isn't exercised here; the e2e suite covers it.
 */
@RunWith(RobolectricTestRunner::class)
class AdminCommandReceiverTest {

    private val context: Application = RuntimeEnvironment.getApplication()
    private val config = LoaderConfig(context)

    private val previousTarget = "com.example.previous"

    private data class Result(val code: Int, val data: String?)

    // What `am broadcast` prints as result=-1, data="OK" and result=1, data="<message>"
    private val ok = Result(-1, "OK")

    private fun error(message: String) = Result(1, message)

    private fun send(action: String, extras: Intent.() -> Unit = {}): Result {
        val receiver = AdminCommandReceiver()
        ContextCompat.registerReceiver(context, receiver, IntentFilter(action), ContextCompat.RECEIVER_NOT_EXPORTED)
        var result: Result? = null
        val resultReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                result = Result(resultCode, resultData)
            }
        }
        try {
            // Same initial result as `am broadcast`: code 0, no data
            context.sendOrderedBroadcast(Intent(action).apply(extras), null, resultReceiver, null, 0, null, null)
            shadowOf(Looper.getMainLooper()).idle()
        } finally {
            context.unregisterReceiver(receiver)
        }
        return checkNotNull(result) { "$action returned no result" }
    }

    @Test
    fun `SET_TARGET switches to an installed launcher app`() {
        TestApps.installLauncherApp(context, "com.example.flat")

        assertEquals(ok, send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, "com.example.flat") })
        assertEquals("com.example.flat", config.targetPackage)
    }

    @Test
    fun `SET_TARGET accepts a VR app that has no launcher entry`() {
        TestApps.installVrOnlyApp(context, "com.example.vr")

        assertEquals(ok, send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, "com.example.vr") })
        assertEquals("com.example.vr", config.targetPackage)
    }

    @Test
    fun `SET_TARGET rejects a package that is not installed`() {
        config.targetPackage = previousTarget

        assertEquals(
            error("No launchable app with package 'com.example.missing'"),
            send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, "com.example.missing") },
        )
        assertEquals(previousTarget, config.targetPackage)
    }

    @Test
    fun `SET_TARGET rejects an installed app that cannot be launched`() {
        TestApps.installAppWithoutLaunchableActivity(context, "com.example.service")
        config.targetPackage = previousTarget

        assertEquals(
            error("No launchable app with package 'com.example.service'"),
            send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, "com.example.service") },
        )
        assertEquals(previousTarget, config.targetPackage)
    }

    @Test
    fun `SET_TARGET without a package is rejected`() {
        config.targetPackage = previousTarget

        assertEquals(error("No launchable app with package ''"), send(ACTION_SET_TARGET))
        assertEquals(error("No launchable app with package ''"), send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, "") })
        assertEquals(error("No launchable app with package ''"), send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, "  ") })
        assertEquals(previousTarget, config.targetPackage)
    }

    @Test
    fun `SET_TARGET trims the package before checking it`() {
        TestApps.installVrOnlyApp(context, "com.example.vr")

        assertEquals(ok, send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, " com.example.vr \n") })
        assertEquals("com.example.vr", config.targetPackage)

        config.targetPackage = previousTarget
        assertEquals(
            error("No launchable app with package 'com.example.missing'"),
            send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, "  com.example.missing ") },
        )
        assertEquals(previousTarget, config.targetPackage)
    }

    @Test
    fun `SET_TARGET rejects the loader itself`() {
        config.targetPackage = previousTarget
        val loader = context.packageName
        val rejected = error("The loader can't be its own target ('$loader')")

        assertEquals(rejected, send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, loader) })
        assertEquals(rejected, send(ACTION_SET_TARGET) { putExtra(EXTRA_PACKAGE, " $loader ") })
        assertEquals(previousTarget, config.targetPackage)
    }

    @Test
    fun `DISABLE and ENABLE switch the watchdog off and on`() {
        assertEquals(ok, send(ACTION_DISABLE))
        assertFalse(config.enabled)

        assertEquals(ok, send(ACTION_ENABLE))
        assertTrue(config.enabled)
    }

    @Test
    fun `PAUSE without minutes pauses for 30 minutes`() {
        val before = System.currentTimeMillis()
        assertEquals(ok, send(ACTION_PAUSE))
        val after = System.currentTimeMillis()

        assertPausedFor(minutes = 30, before, after)
    }

    @Test
    fun `PAUSE pauses for the given minutes`() {
        val before = System.currentTimeMillis()
        assertEquals(ok, send(ACTION_PAUSE) { putExtra(EXTRA_MINUTES, 5) })
        val after = System.currentTimeMillis()

        assertPausedFor(minutes = 5, before, after)
    }

    @Test
    fun `PAUSE for a single minute is accepted`() {
        val before = System.currentTimeMillis()
        assertEquals(ok, send(ACTION_PAUSE) { putExtra(EXTRA_MINUTES, 1) })
        val after = System.currentTimeMillis()

        assertPausedFor(minutes = 1, before, after)
    }

    @Test
    fun `PAUSE with minutes that are not an int is rejected`() {
        val rejected = error("Pass the minutes with --ei, e.g. --ei minutes 30")

        // --es minutes 5, --el minutes 5, --ez minutes true
        assertEquals(rejected, send(ACTION_PAUSE) { putExtra(EXTRA_MINUTES, "5") })
        assertEquals(rejected, send(ACTION_PAUSE) { putExtra(EXTRA_MINUTES, 5L) })
        assertEquals(rejected, send(ACTION_PAUSE) { putExtra(EXTRA_MINUTES, true) })
        assertEquals(0L, config.pausedUntil)
    }

    @Test
    fun `PAUSE for zero or negative minutes is rejected and keeps the current pause`() {
        val pausedUntil = System.currentTimeMillis() + 10 * 60_000L
        config.pausedUntil = pausedUntil

        assertEquals(error("The pause must be at least 1 minute, got 0"), send(ACTION_PAUSE) { putExtra(EXTRA_MINUTES, 0) })
        assertEquals(error("The pause must be at least 1 minute, got -5"), send(ACTION_PAUSE) { putExtra(EXTRA_MINUTES, -5) })
        assertEquals(pausedUntil, config.pausedUntil)
    }

    @Test
    fun `RESUME ends a pause`() {
        config.pausedUntil = System.currentTimeMillis() + 60 * 60_000L

        assertEquals(ok, send(ACTION_RESUME))
        assertEquals(0L, config.pausedUntil)
        assertFalse(config.isPaused())
    }

    @Test
    fun `SET_GRACE sets the grace period`() {
        assertEquals(ok, send(ACTION_SET_GRACE) { putExtra(EXTRA_SECONDS, 45) })
        assertEquals(45, config.graceSeconds)
    }

    @Test
    fun `SET_GRACE accepts 0 and 60 seconds`() {
        assertEquals(ok, send(ACTION_SET_GRACE) { putExtra(EXTRA_SECONDS, 0) })
        assertEquals(0, config.graceSeconds)

        assertEquals(ok, send(ACTION_SET_GRACE) { putExtra(EXTRA_SECONDS, 60) })
        assertEquals(60, config.graceSeconds)
    }

    @Test
    fun `SET_GRACE rejects values outside 0 to 60 seconds`() {
        config.graceSeconds = 20

        for (seconds in listOf(-1, 61, 300, 3600, Int.MIN_VALUE, Int.MAX_VALUE)) {
            assertEquals(
                error("The grace period must be 0 to 60 seconds, got $seconds"),
                send(ACTION_SET_GRACE) { putExtra(EXTRA_SECONDS, seconds) },
            )
        }
        assertEquals(20, config.graceSeconds)
    }

    @Test
    fun `SET_GRACE without seconds as an int is rejected`() {
        config.graceSeconds = 20

        assertEquals(error("Missing --ei seconds"), send(ACTION_SET_GRACE))
        // --es seconds 15, --el seconds 15
        assertEquals(error("Missing --ei seconds"), send(ACTION_SET_GRACE) { putExtra(EXTRA_SECONDS, "15") })
        assertEquals(error("Missing --ei seconds"), send(ACTION_SET_GRACE) { putExtra(EXTRA_SECONDS, 15L) })
        assertEquals(20, config.graceSeconds)
    }

    @Test
    fun `unknown actions are rejected and change nothing`() {
        val action = "com.osamaalek.kiosklauncher.action.REBOOT"

        assertEquals(error("Unknown action $action"), send(action))
        assertEquals(BuildConfig.DEFAULT_TARGET_PACKAGE, config.targetPackage)
        assertTrue(config.enabled)
        assertEquals(LoaderConfig.DEFAULT_GRACE_SECONDS, config.graceSeconds)
        assertEquals(0L, config.pausedUntil)
    }

    private fun assertPausedFor(minutes: Int, before: Long, after: Long) {
        val pausedUntil = config.pausedUntil
        val duration = minutes * 60_000L
        assertTrue(
            "pausedUntil=$pausedUntil not within [${before + duration}, ${after + duration}]",
            pausedUntil in (before + duration)..(after + duration),
        )
        assertTrue(config.isPaused())
    }
}
