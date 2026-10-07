package com.osamaalek.kiosklauncher.ui

import android.app.Application
import android.view.View
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.osamaalek.kiosklauncher.R
import com.osamaalek.kiosklauncher.util.LoaderConfig
import com.osamaalek.kiosklauncher.util.TestApps
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

/** The app list shows every app the loader can keep running, and picking one stores it. */
@RunWith(RobolectricTestRunner::class)
class AppPickerActivityTest {

    private val context: Application = RuntimeEnvironment.getApplication()
    private val config = LoaderConfig(context)

    private lateinit var controller: ActivityController<AppPickerActivity>

    private fun open(): AppPickerActivity {
        controller = Robolectric.buildActivity(AppPickerActivity::class.java).setup()
        return controller.get()
    }

    @After
    fun close() {
        // Leaves LoaderActivity.isVisible false for the next test
        if (::controller.isInitialized) controller.pause().stop().destroy()
    }

    /** The rows, laid out so that every one is bound. */
    private fun rows(activity: AppPickerActivity): List<View> {
        val list = activity.findViewById<RecyclerView>(R.id.recyclerView_apps)
        list.measure(
            View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(10_000, View.MeasureSpec.EXACTLY),
        )
        list.layout(0, 0, 1080, 10_000)
        return (0 until list.childCount).map { list.getChildAt(it) }
    }

    private fun View.packageName() = findViewById<TextView>(R.id.app_package).text.toString()
    private fun View.isMarkedCurrent() = findViewById<View>(R.id.app_current).visibility == View.VISIBLE

    @Test
    fun `lists launcher and VR-only apps, but not the loader or apps it can't launch`() {
        TestApps.installLauncherApp(context, "com.example.headjacklive")
        TestApps.installVrOnlyApp(context, "com.example.sideloaded")
        TestApps.installAppWithoutLaunchableActivity(context, "com.example.service")

        val shown = rows(open()).map { it.packageName() }.toSet()

        assertEquals(setOf("com.example.headjacklive", "com.example.sideloaded"), shown)
    }

    @Test
    fun `marks the current target`() {
        TestApps.installLauncherApp(context, "com.example.headjacklive")
        TestApps.installLauncherApp(context, "com.example.other")
        config.targetPackage = "com.example.headjacklive"

        val marked = rows(open()).filter { it.isMarkedCurrent() }.map { it.packageName() }

        assertEquals(listOf("com.example.headjacklive"), marked)
    }

    @Test
    fun `tapping an app makes it the target and closes the list`() {
        TestApps.installLauncherApp(context, "com.example.headjacklive")
        TestApps.installVrOnlyApp(context, "com.example.sideloaded")
        config.targetPackage = "com.example.headjacklive"
        val activity = open()

        rows(activity).single { it.packageName() == "com.example.sideloaded" }.performClick()

        assertEquals("com.example.sideloaded", config.targetPackage)
        assertTrue(activity.isFinishing)
    }

    @Test
    fun `says so when there is nothing to pick`() {
        val activity = open()

        assertTrue(rows(activity).isEmpty())
        assertEquals(View.VISIBLE, activity.findViewById<View>(R.id.text_picker_empty).visibility)
        assertFalse(activity.isFinishing)
    }
}
