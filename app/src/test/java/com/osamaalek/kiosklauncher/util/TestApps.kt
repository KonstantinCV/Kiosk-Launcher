package com.osamaalek.kiosklauncher.util

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import org.robolectric.Shadows.shadowOf

/** Fake installed apps for Robolectric tests, registered with the shadow package manager. */
object TestApps {

    /** A regular app, started from its MAIN/LAUNCHER activity. */
    fun installLauncherApp(context: Context, packageName: String, activity: String = "$packageName.MainActivity") =
        install(context, packageName, activity, Intent.CATEGORY_LAUNCHER)

    /** A Quest VR app that only declares MAIN with the Oculus VR category, and no launcher entry. */
    fun installVrOnlyApp(context: Context, packageName: String, activity: String = "$packageName.VrActivity") =
        install(context, packageName, activity, TargetLauncher.CATEGORY_VR)

    /** An installed app without any MAIN activity, e.g. a background service or a plugin. */
    fun installAppWithoutLaunchableActivity(context: Context, packageName: String) {
        val component = ComponentName(packageName, "$packageName.SettingsActivity")
        shadowOf(context.packageManager).addActivityIfNotPresent(component)
    }

    private fun install(context: Context, packageName: String, activity: String, category: String): ComponentName {
        val component = ComponentName(packageName, activity)
        val packageManager = shadowOf(context.packageManager)
        packageManager.addActivityIfNotPresent(component)
        packageManager.addIntentFilterForActivity(
            component,
            IntentFilter(Intent.ACTION_MAIN).apply { addCategory(category) },
        )
        return component
    }
}
