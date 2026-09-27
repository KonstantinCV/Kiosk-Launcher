package com.osamaalek.kiosklauncher.util

import android.content.Context
import android.content.Intent
import com.osamaalek.kiosklauncher.model.AppInfo

object AppsUtil {

    /** Launchable apps, including Quest VR apps, without the loader itself. */
    fun getAllApps(context: Context): List<AppInfo> {
        val pm = context.packageManager
        val categories = listOf(Intent.CATEGORY_LAUNCHER, TargetLauncher.CATEGORY_VR)
        return categories
            .flatMap { category ->
                pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0)
            }
            .distinctBy { it.activityInfo.packageName }
            .filter { it.activityInfo.packageName != context.packageName }
            .map { AppInfo(it.loadLabel(pm), it.activityInfo.packageName, it.activityInfo.loadIcon(pm)) }
            .sortedBy { it.label.toString().lowercase() }
    }
}
