package com.osamaalek.kiosklauncher.watchdog

/**
 * Decides when the target app has to be (re)launched. Plain Kotlin with no Android
 * dependencies so it can be unit tested on the JVM.
 *
 * The target is launched once it has been out of the foreground for [Snapshot.graceMs].
 * The same rule covers first boot, a normal exit and a crash: in every case some other
 * activity (usually the Horizon home) takes the foreground.
 */
class WatchdogPolicy {

    enum class Decision { IDLE, WAIT, LAUNCH }

    data class Snapshot(
        val now: Long,
        val targetPackage: String,
        val enabled: Boolean,
        val paused: Boolean,
        val loaderUiVisible: Boolean,
        val interactive: Boolean,
        /** Whether usage access is granted, so [foregroundPackage] can be trusted. */
        val foregroundKnown: Boolean,
        val foregroundPackage: String?,
        val graceMs: Long,
        /** Used without usage access: how often to bring the target back to the front. */
        val blindIntervalMs: Long,
    )

    private var notTargetSince: Long? = null
    private var lastLaunchAt: Long? = null

    fun evaluate(s: Snapshot): Decision {
        if (!s.enabled || s.targetPackage.isEmpty() || s.paused || s.loaderUiVisible || !s.interactive) {
            // Sleeping headset, admin in the loader UI, or nothing to run: start the grace period over
            notTargetSince = null
            return Decision.IDLE
        }
        if (s.foregroundKnown && s.foregroundPackage == s.targetPackage) {
            notTargetSince = null
            return Decision.IDLE
        }

        val since = notTargetSince ?: s.now.also { notTargetSince = it }
        if (s.now - since < s.graceMs) return Decision.WAIT

        if (!s.foregroundKnown) {
            // Can't see the foreground app, so relaunching is the only way to recover from a crash.
            // A launch intent for an app that is already in front just brings its task forward.
            val last = lastLaunchAt
            if (last != null && s.now - last < s.blindIntervalMs) return Decision.WAIT
        }

        // Give the launch its own grace period before trying again
        notTargetSince = s.now
        lastLaunchAt = s.now
        return Decision.LAUNCH
    }
}
