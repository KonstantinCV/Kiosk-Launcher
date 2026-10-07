package com.osamaalek.kiosklauncher.watchdog

/**
 * Folds activity events (from UsageStatsManager) into the set of activities that are resumed,
 * keyed by package and class. More than one can be resumed at once: Quest panels, a system
 * overlay above the target, or an app's next activity reported before its previous one paused.
 */
class ForegroundState {

    /** Oldest first, so the last one is the most recently resumed. */
    private val resumed = LinkedHashSet<Pair<String, String>>()

    /** Package of the most recently resumed activity that still is; null if none is known. */
    val foregroundPackage: String?
        get() = resumed.lastOrNull()?.first

    /** Whether any activity of [packageName] is resumed. */
    fun isResumed(packageName: String) = resumed.any { it.first == packageName }

    /** Whether any resumed activity matches [predicate] (package, class). */
    fun anyResumed(predicate: (String, String) -> Boolean) = resumed.any { predicate(it.first, it.second) }

    fun onResumed(packageName: String, className: String) {
        val activity = packageName to className
        // Re-adding moves it to the end
        resumed.remove(activity)
        resumed.add(activity)
    }

    /** The activity paused or stopped: either way it is no longer resumed. */
    fun onPaused(packageName: String, className: String) {
        resumed.remove(packageName to className)
    }

    fun clear() = resumed.clear()
}
