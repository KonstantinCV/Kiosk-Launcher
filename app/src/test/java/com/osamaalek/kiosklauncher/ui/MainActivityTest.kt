package com.osamaalek.kiosklauncher.ui

import android.app.Application
import android.os.SystemClock
import android.view.KeyEvent
import android.view.MotionEvent
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.widget.SwitchCompat
import com.osamaalek.kiosklauncher.R
import com.osamaalek.kiosklauncher.util.LoaderConfig
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.android.controller.ActivityController

/** The settings screen writes a setting only when the user changes it, over the whole allowed range. */
@RunWith(RobolectricTestRunner::class)
class MainActivityTest {

    private val context: Application = RuntimeEnvironment.getApplication()
    private val config = LoaderConfig(context)

    private lateinit var controller: ActivityController<MainActivity>

    private val enabledSwitch get() = controller.get().findViewById<SwitchCompat>(R.id.switch_enabled)
    private val graceSeek get() = controller.get().findViewById<SeekBar>(R.id.seek_grace)
    private val graceText get() = controller.get().findViewById<TextView>(R.id.text_grace)

    private fun open() {
        controller = Robolectric.buildActivity(MainActivity::class.java).setup()
    }

    @After
    fun close() {
        // Leaves LoaderActivity.isVisible false for the next test
        if (::controller.isInitialized) controller.pause().stop().destroy()
    }

    @Test
    fun `the switch shows the setting`() {
        config.enabled = false
        open()

        assertFalse(enabledSwitch.isChecked)
        assertFalse(config.enabled)
    }

    @Test
    fun `recreating the screen does not undo a DISABLE sent while it was open`() {
        open()
        assertTrue(enabledSwitch.isChecked)

        // adb DISABLE while the screen is open: nothing refreshes it until it is resumed again
        config.enabled = false
        // e.g. a Quest panel resize: the old screen's state is saved and handed to a new one
        controller.recreate()

        assertFalse(config.enabled)
        assertFalse(enabledSwitch.isChecked)
    }

    @Test
    fun `tapping the switch turns the watchdog off and on`() {
        open()

        enabledSwitch.performClick()
        assertFalse(config.enabled)

        enabledSwitch.performClick()
        assertTrue(config.enabled)
    }

    @Test
    fun `dragging the switch thumb across turns the watchdog off`() {
        open()
        val switch = enabledSwitch
        assertTrue("the switch was not laid out", switch.width > 0 && switch.height > 0)
        assertTrue(switch.isChecked)

        // Checked, the thumb is at the right end. Dragging it doesn't click the switch.
        val x = (switch.width - switch.paddingRight - 4).toFloat()
        val y = switch.height / 2f
        val down = SystemClock.uptimeMillis()
        fun touch(action: Int, dx: Float, at: Long) {
            val event = MotionEvent.obtain(down, down + at, action, x + dx, y, 0)
            switch.dispatchTouchEvent(event)
            event.recycle()
        }
        touch(MotionEvent.ACTION_DOWN, 0f, 0)
        touch(MotionEvent.ACTION_MOVE, -40f, 100)
        touch(MotionEvent.ACTION_MOVE, -switch.width.toFloat(), 1_000)
        touch(MotionEvent.ACTION_UP, -switch.width.toFloat(), 2_000)

        assertFalse(switch.isChecked)
        assertFalse(config.enabled)
    }

    @Test
    fun `the grace slider covers the range the setting allows`() {
        config.graceSeconds = 120
        open()

        assertEquals(LoaderConfig.MIN_GRACE_SECONDS, graceSeek.min)
        assertEquals(LoaderConfig.MAX_GRACE_SECONDS, graceSeek.max)
        assertEquals(120, graceSeek.progress)
        assertEquals(context.getString(R.string.grace_label, 120), graceText.text.toString())
    }

    @Test
    fun `moving the grace slider stores what it shows`() {
        config.graceSeconds = 120
        open()

        // One step down, the way the controller's or a keyboard's arrow key moves it
        graceSeek.onKeyDown(KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_DPAD_LEFT))

        val shown = graceSeek.progress
        assertTrue("slider at $shown, expected a step below 120", shown in 61 until 120)
        assertEquals(shown, config.graceSeconds)
        assertEquals(context.getString(R.string.grace_label, shown), graceText.text.toString())
    }
}
