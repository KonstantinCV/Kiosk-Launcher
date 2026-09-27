package com.osamaalek.kiosklauncher.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.osamaalek.kiosklauncher.R
import com.osamaalek.kiosklauncher.ui.LoaderActivity
import com.osamaalek.kiosklauncher.ui.MainActivity
import com.osamaalek.kiosklauncher.util.LoaderConfig
import com.osamaalek.kiosklauncher.util.Permissions
import com.osamaalek.kiosklauncher.util.TargetLauncher
import com.osamaalek.kiosklauncher.watchdog.LaunchBackoff
import com.osamaalek.kiosklauncher.watchdog.WatchdogPolicy

/**
 * Foreground service that keeps the target app running: it launches it after boot and
 * relaunches it whenever it leaves the foreground (exit or crash) while the headset is awake.
 */
class WatchdogService : Service() {

    private val handler = Handler(Looper.getMainLooper())
    private lateinit var config: LoaderConfig
    private lateinit var tracker: ForegroundTracker
    private lateinit var powerManager: PowerManager
    private val policy = WatchdogPolicy()
    private val backoff = LaunchBackoff()

    private val tick = object : Runnable {
        override fun run() {
            evaluate()
            handler.postDelayed(this, TICK_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        config = LoaderConfig(this)
        tracker = ForegroundTracker(this)
        powerManager = getSystemService(PowerManager::class.java)

        createChannel()
        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            } else {
                0
            }
        )
        handler.post(tick)
        Log.i(TAG, "Watchdog started, target=${config.targetPackage}")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(tick)
        super.onDestroy()
    }

    private fun evaluate() {
        val now = System.currentTimeMillis()
        val target = config.targetPackage
        val foregroundKnown = Permissions.hasUsageAccess(this)
        val foreground = if (foregroundKnown) tracker.update(now) else null

        val decision = policy.evaluate(
            WatchdogPolicy.Snapshot(
                now = now,
                targetPackage = target,
                enabled = config.enabled,
                paused = config.isPaused(now),
                loaderUiVisible = LoaderActivity.isVisible,
                interactive = powerManager.isInteractive,
                foregroundKnown = foregroundKnown,
                foregroundPackage = foreground,
                graceMs = config.graceSeconds * 1000L,
                blindIntervalMs = BLIND_INTERVAL_MS,
            )
        )
        if (decision != WatchdogPolicy.Decision.LAUNCH) return

        if (!backoff.tryAcquire(now)) {
            Log.w(TAG, "$target keeps exiting, relaunch throttled")
            return
        }
        Log.i(TAG, "Relaunching $target (foreground: ${foreground ?: "unknown"})")
        TargetLauncher.launch(this, target)
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID, getString(R.string.notification_channel), NotificationManager.IMPORTANCE_MIN
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val target = config.targetPackage
        val text = if (target.isEmpty()) {
            getString(R.string.notification_no_target)
        } else {
            getString(R.string.notification_watching, target)
        }
        val openUi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(openUi)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()
    }

    companion object {
        private const val TAG = "WatchdogService"
        private const val CHANNEL_ID = "watchdog"
        private const val NOTIFICATION_ID = 1
        private const val TICK_MS = 2_000L
        private const val BLIND_INTERVAL_MS = 30_000L

        /**
         * Starts (or refreshes) the service. Allowed from an activity, from BOOT_COMPLETED and,
         * with the overlay grant, from the background; otherwise Android refuses and we log it.
         */
        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(context, Intent(context, WatchdogService::class.java))
            } catch (e: IllegalStateException) {
                Log.w(TAG, "Not allowed to start the watchdog right now", e)
            }
        }
    }
}
