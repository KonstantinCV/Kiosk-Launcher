package com.osamaalek.kiosklauncher.util

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.util.Log

object TargetLauncher {

    /** Launcher category used by Quest VR apps, some of which don't declare CATEGORY_LAUNCHER. */
    const val CATEGORY_VR = "com.oculus.intent.category.VR"

    private const val TAG = "TargetLauncher"

    fun launchIntent(context: Context, packageName: String): Intent? {
        val pm = context.packageManager
        pm.getLaunchIntentForPackage(packageName)?.let { return it }

        val vrIntent = Intent(Intent.ACTION_MAIN).addCategory(CATEGORY_VR).setPackage(packageName)
        val activity = pm.queryIntentActivities(vrIntent, 0).firstOrNull()?.activityInfo ?: return null
        return Intent(Intent.ACTION_MAIN)
            .addCategory(CATEGORY_VR)
            .setClassName(activity.packageName, activity.name)
    }

    fun isInstalled(context: Context, packageName: String) =
        packageName.isNotEmpty() && launchIntent(context, packageName) != null

    /**
     * Starts the target the same way tapping its icon would: a new task, or the existing
     * task brought to the front. Returns false if the app can't be launched at all.
     * A launch blocked by background-start restrictions fails silently, so callers
     * still need to check that the target actually came up.
     */
    fun launch(context: Context, packageName: String): Boolean {
        val intent = launchIntent(context, packageName) ?: run {
            Log.w(TAG, "No launchable activity for $packageName")
            return false
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            context.startActivity(intent)
            Log.i(TAG, "Launched $packageName")
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "Launch of $packageName failed", e)
            false
        } catch (e: SecurityException) {
            Log.w(TAG, "Launch of $packageName failed", e)
            false
        }
    }
}
