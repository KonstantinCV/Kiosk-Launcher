package com.osamaalek.kiosklauncher.watchdog

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DialogWaitTest {

    private val wait = DialogWait(maxWaitMs = 60_000)

    @Test
    fun `holds off while a dialog is in front, for at most the maximum`() {
        assertTrue(wait.holding(0, dialogInFront = true))
        assertTrue(wait.holding(59_999, dialogInFront = true))
        assertFalse(wait.holding(60_000, dialogInFront = true))
        assertFalse(wait.holding(10 * 60_000, dialogInFront = true))
    }

    @Test
    fun `does not hold off without a dialog`() {
        assertFalse(wait.holding(0, dialogInFront = false))
    }

    @Test
    fun `a dialog that closes and comes back gets the full wait again`() {
        assertTrue(wait.holding(0, dialogInFront = true))
        assertFalse(wait.holding(70_000, dialogInFront = true))
        assertFalse(wait.holding(72_000, dialogInFront = false))
        assertTrue(wait.holding(74_000, dialogInFront = true))
        assertTrue(wait.holding(130_000, dialogInFront = true))
        assertFalse(wait.holding(134_000, dialogInFront = true))
    }
}
