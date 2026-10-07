package com.osamaalek.kiosklauncher.watchdog

/**
 * How long the watchdog holds off for a dialog that is in front (see [HorizonDialogs]): for as
 * long as it stays in front, but at most [maxWaitMs]. A dialog nobody deals with, or one whose
 * closing was never recorded, then no longer keeps the target from being launched; the
 * crash-loop guard still limits how often. Times come from a monotonic clock.
 */
class DialogWait(private val maxWaitMs: Long = 60_000L) {

    private var since: Long? = null

    /** Whether to hold off now, given whether such a dialog is in front. */
    fun holding(now: Long, dialogInFront: Boolean): Boolean {
        if (!dialogInFront) {
            since = null
            return false
        }
        val start = since ?: now.also { since = it }
        return now - start < maxWaitMs
    }
}
