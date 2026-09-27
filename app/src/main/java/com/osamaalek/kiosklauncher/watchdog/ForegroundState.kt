package com.osamaalek.kiosklauncher.watchdog

/**
 * Folds activity resume/pause events (from UsageStatsManager) into the package that is
 * currently in the foreground. Null means nothing is known to be resumed.
 */
class ForegroundState {

    var foregroundPackage: String? = null
        private set

    fun onResumed(packageName: String) {
        foregroundPackage = packageName
    }

    fun onPaused(packageName: String) {
        if (packageName == foregroundPackage) foregroundPackage = null
    }
}
