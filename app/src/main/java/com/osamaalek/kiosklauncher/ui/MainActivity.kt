package com.osamaalek.kiosklauncher.ui

import android.content.Intent
import android.os.Bundle
import android.text.format.DateFormat
import android.widget.Button
import android.widget.ImageView
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.widget.SwitchCompat
import com.osamaalek.kiosklauncher.R
import com.osamaalek.kiosklauncher.service.WatchdogService
import com.osamaalek.kiosklauncher.util.LoaderConfig
import com.osamaalek.kiosklauncher.util.Permissions
import com.osamaalek.kiosklauncher.util.TargetLauncher
import java.util.Date

/**
 * Status and settings screen. While it (or the app picker) is open the watchdog stands down,
 * so an operator can change the target app without it being relaunched on top of them.
 */
class MainActivity : LoaderActivity() {

    private lateinit var config: LoaderConfig

    private lateinit var targetIcon: ImageView
    private lateinit var targetLabel: TextView
    private lateinit var targetPackage: TextView
    private lateinit var enabledSwitch: SwitchCompat
    private lateinit var graceText: TextView
    private lateinit var graceSeek: SeekBar
    private lateinit var pauseState: TextView
    private lateinit var pauseButton: Button
    private lateinit var usageAccess: TextView
    private lateinit var backgroundLaunch: TextView
    private lateinit var adbCommands: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        config = LoaderConfig(this)

        targetIcon = findViewById(R.id.image_target_icon)
        targetLabel = findViewById(R.id.text_target_label)
        targetPackage = findViewById(R.id.text_target_package)
        enabledSwitch = findViewById(R.id.switch_enabled)
        graceText = findViewById(R.id.text_grace)
        graceSeek = findViewById(R.id.seek_grace)
        pauseState = findViewById(R.id.text_pause_state)
        pauseButton = findViewById(R.id.button_pause)
        usageAccess = findViewById(R.id.text_usage_access)
        backgroundLaunch = findViewById(R.id.text_background_launch)
        adbCommands = findViewById(R.id.text_adb_commands)

        findViewById<Button>(R.id.button_choose_app).setOnClickListener {
            startActivity(Intent(this, AppPickerActivity::class.java))
        }
        findViewById<Button>(R.id.button_launch_now).setOnClickListener {
            TargetLauncher.launch(this, config.targetPackage)
        }
        // Only the user's changes are written. The switch doesn't save and restore its state: a
        // recreated screen would restore a copy that an adb ENABLE/DISABLE may have made stale,
        // and write it back. refresh() shows the setting, which the check keeps from being
        // written again. A click listener would miss the thumb being dragged across.
        enabledSwitch.isSaveEnabled = false
        enabledSwitch.setOnCheckedChangeListener { _, checked ->
            if (checked != config.enabled) config.enabled = checked
        }

        graceSeek.min = LoaderConfig.MIN_GRACE_SECONDS
        graceSeek.max = LoaderConfig.MAX_GRACE_SECONDS
        graceSeek.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar, progress: Int, fromUser: Boolean) {
                if (fromUser) config.graceSeconds = progress
                graceText.text = getString(R.string.grace_label, progress)
            }

            override fun onStartTrackingTouch(seekBar: SeekBar) = Unit
            override fun onStopTrackingTouch(seekBar: SeekBar) = Unit
        })

        pauseButton.setOnClickListener {
            config.pausedUntil = if (config.isPaused()) 0L else System.currentTimeMillis() + PAUSE_MS
            refresh()
        }

        adbCommands.text = adbSetupCommands()

        // First launch, or the target was uninstalled: go straight to the app list. Not when the
        // screen is only recreated, so backing out of the list leaves it closed.
        if (savedInstanceState == null && !TargetLauncher.isInstalled(this, config.targetPackage)) {
            startActivity(Intent(this, AppPickerActivity::class.java))
        }
    }

    override fun onResume() {
        super.onResume()
        // Covers the first run after install, before any BOOT_COMPLETED has been delivered
        WatchdogService.start(this)
        refresh()
    }

    private fun refresh() {
        val target = config.targetPackage
        val launchIntent = if (target.isEmpty()) null else TargetLauncher.launchIntent(this, target)
        val appInfo = launchIntent?.let { packageManager.resolveActivity(it, 0)?.activityInfo }
        targetIcon.setImageDrawable(appInfo?.loadIcon(packageManager))
        targetLabel.text = when {
            target.isEmpty() -> getString(R.string.no_target)
            appInfo == null -> getString(R.string.target_missing)
            else -> appInfo.loadLabel(packageManager)
        }
        targetPackage.text = target

        enabledSwitch.isChecked = config.enabled
        graceSeek.progress = config.graceSeconds
        graceText.text = getString(R.string.grace_label, config.graceSeconds)

        if (config.isPaused()) {
            pauseState.text = getString(
                R.string.paused_until, DateFormat.getTimeFormat(this).format(Date(config.pausedUntil))
            )
            pauseButton.setText(R.string.resume_button)
        } else {
            pauseState.setText(R.string.not_paused)
            pauseButton.setText(R.string.pause_button)
        }

        usageAccess.setText(
            if (Permissions.hasUsageAccess(this)) R.string.usage_access_ok else R.string.usage_access_missing
        )
        backgroundLaunch.setText(
            when {
                Permissions.canDrawOverlays(this) -> R.string.background_launch_overlay
                Permissions.isDeviceOwner(this) -> R.string.background_launch_owner
                else -> R.string.background_launch_missing
            }
        )
    }

    private fun adbSetupCommands(): String {
        val pkg = packageName
        return """
            adb shell appops set $pkg SYSTEM_ALERT_WINDOW allow
            adb shell appops set $pkg GET_USAGE_STATS allow
            adb shell dumpsys deviceidle whitelist +$pkg
        """.trimIndent()
    }

    companion object {
        private const val PAUSE_MS = 30 * 60_000L
    }
}
