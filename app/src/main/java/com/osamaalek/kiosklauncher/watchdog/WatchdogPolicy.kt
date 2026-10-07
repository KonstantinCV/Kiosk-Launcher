package com.osamaalek.kiosklauncher.watchdog

/**
 * Decides when the target app has to be (re)launched. Plain Kotlin with no Android
 * dependencies so it can be unit tested on the JVM.
 *
 * The target is launched once none of its activities has been resumed for [Snapshot.graceMs].
 * The same rule covers first boot, a normal exit and a crash. [evaluate] only asks for a launch;
 * the caller reports the ones it makes with [onLaunched], so a launch it can't make (target not
 * installed) neither restarts the grace period nor counts against the crash-loop [backoff].
 */
class WatchdogPolicy(private val backoff: LaunchBackoff = LaunchBackoff()) {

    enum class Decision { IDLE, WAIT, LAUNCH, THROTTLED }

    data class Snapshot(
        /** Monotonic (SystemClock.elapsedRealtime), so wall-clock changes don't move the timers. */
        val now: Long,
        val targetPackage: String,
        val enabled: Boolean,
        val paused: Boolean,
        val loaderUiVisible: Boolean,
        val interactive: Boolean,
        /** Whether usage access is granted, so the next three can be trusted. */
        val foregroundKnown: Boolean,
        /** Whether any activity of the target is resumed. */
        val targetResumed: Boolean,
        /** The most recently resumed app that still is; null if no activity is known to be resumed. */
        val foregroundPackage: String?,
        /** Grows with every activity event seen; unchanged means nothing was resumed or paused. */
        val activityEvents: Int,
        val graceMs: Long,
        /** Used without usage access: how often to bring the target back to the front. */
        val blindIntervalMs: Long,
        /**
         * Something in front holds every launch up (Guardian): a launch now is retried as usual,
         * but isn't a crash, so the backoff doesn't count it.
         */
        val launchesHeldUp: Boolean = false,
    )

    private class Launch(
        val at: Long,
        val targetPackage: String,
        /** Nothing was known to be resumed when it was made. */
        val intoUnknown: Boolean,
        val activityEvents: Int,
    )

    private var notTargetSince: Long? = null
    private var lastLaunch: Launch? = null

    fun evaluate(s: Snapshot): Decision {
        if (!s.enabled || s.targetPackage.isEmpty() || s.paused || s.loaderUiVisible || !s.interactive) {
            // Sleeping headset, admin in the loader UI, or nothing to run: start the grace period over
            notTargetSince = null
            return Decision.IDLE
        }
        if (s.foregroundKnown && (s.targetResumed || alreadyInFront(s))) {
            notTargetSince = null
            return Decision.IDLE
        }

        val since = notTargetSince ?: s.now.also { notTargetSince = it }
        if (s.now - since < s.graceMs) return Decision.WAIT

        if (!s.foregroundKnown) {
            // Can't see the foreground app, so relaunching is the only way to recover from a crash.
            // A launch intent for an app that is already in front just brings its task forward.
            // Those periodic launches aren't a crash loop, so the backoff doesn't count them.
            val last = lastLaunch
            if (last != null && s.now - last.at < s.blindIntervalMs) return Decision.WAIT
        } else if (!backoff.canLaunch(s.now)) {
            return Decision.THROTTLED
        }
        return Decision.LAUNCH
    }

    /** The caller launched the target, as asked by [evaluate] for [s]. */
    fun onLaunched(s: Snapshot) {
        // Give the launch its own grace period before trying again
        notTargetSince = s.now
        if (s.foregroundKnown && !s.launchesHeldUp) backoff.onLaunched(s.now)
        val intoUnknown = s.foregroundKnown && s.foregroundPackage == null
        lastLaunch = Launch(s.now, s.targetPackage, intoUnknown, s.activityEvents)
    }

    /**
     * Launching an app whose activity is already resumed on top changes nothing, so no event
     * follows. When nothing was known to be resumed before the launch (the target came up before
     * the events the tracker reads) and a whole grace period passed without an event, the target
     * was already in front. Not when another app was known to be in front: then the silence means
     * the launch was blocked, and it has to be retried.
     */
    private fun alreadyInFront(s: Snapshot): Boolean {
        val launch = lastLaunch ?: return false
        return launch.intoUnknown && launch.targetPackage == s.targetPackage &&
            launch.activityEvents == s.activityEvents && s.now - launch.at >= s.graceMs
    }
}
