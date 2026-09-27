package com.osamaalek.kiosklauncher.watchdog

/**
 * Crash-loop guard: after [maxLaunches] launches inside [windowMs], only one launch is
 * allowed per [cooldownMs] until the target stays up again. Times come from a monotonic clock.
 */
class LaunchBackoff(
    private val maxLaunches: Int = 5,
    private val windowMs: Long = 3 * 60_000L,
    private val cooldownMs: Long = 60_000L,
) {
    private val launches = ArrayDeque<Long>()

    /** Whether a launch is allowed now. Asking doesn't count as one: report it with [onLaunched]. */
    fun canLaunch(now: Long): Boolean {
        while (launches.isNotEmpty() && now - launches.first() > windowMs) launches.removeFirst()
        return launches.size < maxLaunches || now - launches.last() >= cooldownMs
    }

    fun onLaunched(now: Long) {
        launches.addLast(now)
    }
}
