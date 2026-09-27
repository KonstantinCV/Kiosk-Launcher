package com.osamaalek.kiosklauncher.watchdog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ForegroundStateTest {

    private val state = ForegroundState()

    @Test
    fun `tracks the last resumed app`() {
        state.onResumed("a")
        state.onPaused("a")
        state.onResumed("b")
        assertEquals("b", state.foregroundPackage)
    }

    @Test
    fun `a pause of the foreground app clears it`() {
        state.onResumed("a")
        state.onPaused("a")
        assertNull(state.foregroundPackage)
    }

    @Test
    fun `a late pause of another app is ignored`() {
        state.onResumed("a")
        state.onResumed("b")
        state.onPaused("a")
        assertEquals("b", state.foregroundPackage)
    }
}
