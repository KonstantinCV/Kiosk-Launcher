package com.osamaalek.kiosklauncher.watchdog

/**
 * Crash-loop guard: after [maxLaunches] launches inside [windowMs], only one launch is
 * allowed per [cooldownMs] until the target stays up again.
 */
class LaunchBackoff(
    private val maxLaunches: Int = 5,
    private val windowMs: Long = 3 * 60_000L,
    private val cooldownMs: Long = 60_000L,
) {
    private val launches = ArrayDeque<Long>()

    fun tryAcquire(now: Long): Boolean {
        while (launches.isNotEmpty() && now - launches.first() > windowMs) launches.removeFirst()
        if (launches.size >= maxLaunches && now - launches.last() < cooldownMs) return false
        launches.addLast(now)
        return true
    }
}
