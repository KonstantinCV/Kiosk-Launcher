package com.osamaalek.kiosklauncher.watchdog

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundStateTest {

    private val state = ForegroundState()

    @Test
    fun `tracks the last resumed app`() {
        state.onResumed("a", "A")
        state.onPaused("a", "A")
        state.onResumed("b", "B")
        assertEquals("b", state.foregroundPackage)
    }

    @Test
    fun `a pause of the foreground app clears it`() {
        state.onResumed("a", "A")
        state.onPaused("a", "A")
        assertNull(state.foregroundPackage)
        assertFalse(state.isResumed("a"))
    }

    @Test
    fun `a late pause of another app is ignored`() {
        state.onResumed("a", "A")
        state.onResumed("b", "B")
        state.onPaused("a", "A")
        assertEquals("b", state.foregroundPackage)
    }

    @Test
    fun `an app stays resumed while an overlay comes and goes`() {
        state.onResumed("t", "Main")
        state.onResumed("overlay", "Menu")
        assertTrue(state.isResumed("t"))
        assertEquals("overlay", state.foregroundPackage)
        state.onPaused("overlay", "Menu")
        assertTrue(state.isResumed("t"))
        assertEquals("t", state.foregroundPackage)
    }

    @Test
    fun `an app is resumed while any of its activities is`() {
        state.onResumed("t", "A")
        state.onResumed("t", "B")
        state.onPaused("t", "A")
        assertTrue(state.isResumed("t"))
        state.onPaused("t", "B")
        assertFalse(state.isResumed("t"))
    }

    @Test
    fun `the foreground is the most recently resumed activity that still is`() {
        state.onResumed("a", "A")
        state.onResumed("b", "B")
        state.onResumed("a", "A")
        assertEquals("a", state.foregroundPackage)
        state.onPaused("a", "A")
        assertEquals("b", state.foregroundPackage)
    }

    @Test
    fun `clear forgets every resumed activity`() {
        state.onResumed("a", "A")
        state.onResumed("b", "B")
        state.clear()
        assertNull(state.foregroundPackage)
        assertFalse(state.isResumed("a"))
    }
}
