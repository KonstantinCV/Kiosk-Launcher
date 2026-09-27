package com.osamaalek.kiosklauncher.util

import android.app.AppOpsManager
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Process
import android.provider.Settings

/** The one-time grants the watchdog relies on. All of them can be given over adb. */
object Permissions {

    /** Needed to see which app is in the foreground, and so to detect exits and crashes. */
    fun hasUsageAccess(context: Context): Boolean {
        val appOps = context.getSystemService(AppOpsManager::class.java)
        return when (appOps.unsafeCheckOpNoThrow(
            AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName
        )) {
            AppOpsManager.MODE_ALLOWED -> true
            AppOpsManager.MODE_DEFAULT -> context.checkSelfPermission(
                android.Manifest.permission.PACKAGE_USAGE_STATS
            ) == PackageManager.PERMISSION_GRANTED
            else -> false
        }
    }

    /** Exempts the app from Android's block on starting activities from the background. */
    fun canDrawOverlays(context: Context) = Settings.canDrawOverlays(context)

    /** Device owner is an alternative exemption from the background-start block. */
    fun isDeviceOwner(context: Context) =
        context.getSystemService(DevicePolicyManager::class.java).isDeviceOwnerApp(context.packageName)

    fun canLaunchFromBackground(context: Context) = canDrawOverlays(context) || isDeviceOwner(context)
}
