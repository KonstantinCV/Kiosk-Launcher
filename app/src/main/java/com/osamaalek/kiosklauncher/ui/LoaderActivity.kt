package com.osamaalek.kiosklauncher.ui

import androidx.appcompat.app.AppCompatActivity

/** Base for the loader's own screens: the watchdog stands down while one of them is in front. */
abstract class LoaderActivity : AppCompatActivity() {

    override fun onResume() {
        super.onResume()
        isVisible = true
    }

    override fun onPause() {
        isVisible = false
        super.onPause()
    }

    companion object {
        @Volatile
        var isVisible = false
            private set
    }
}
