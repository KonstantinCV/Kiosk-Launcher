package com.osamaalek.kiosklauncher.receiver

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.osamaalek.kiosklauncher.service.WatchdogService

/** Starts the watchdog once the headset has booted, or after the loader itself was updated. */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED -> WatchdogService.start(context)
        }
    }
}
