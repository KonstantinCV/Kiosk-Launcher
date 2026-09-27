package com.osamaalek.kiosklauncher.testapp

import android.app.Activity
import android.content.Context
import android.os.Bundle
import android.os.Process
import android.util.Log
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import java.lang.ref.WeakReference

/**
 * The app the loader keeps running, in the e2e suite (e2e/). Test-only: never shipped.
 *
 * Logs its lifecycle under the tag "E2ETarget" ("RESUMED pkg=<package> pid=<pid>"), so the
 * suite can tell when it is in front and whether a relaunch started a new process.
 */
class TargetActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        current = WeakReference(this)
        logEvent("CREATED")
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        setContentView(TextView(this).apply {
            text = getString(R.string.target_text, applicationInfo.loadLabel(packageManager), Process.myPid())
            textSize = 32f
            gravity = Gravity.CENTER
        })
    }

    override fun onResume() {
        super.onResume()
        logEvent("RESUMED")
    }

    override fun onPause() {
        logEvent("PAUSED")
        super.onPause()
    }

    override fun onDestroy() {
        logEvent("DESTROYED")
        if (current?.get() === this) current = null
        super.onDestroy()
    }

    companion object {
        const val TAG = "E2ETarget"

        // singleTask: there is at most one. Only used on the main thread.
        private var current: WeakReference<TargetActivity>? = null

        /** The running TargetActivity, if there is one. */
        fun current(): TargetActivity? = current?.get()
    }
}

/** Logs "<event> pkg=<package> pid=<pid>" under [TargetActivity.TAG]. */
fun Context.logEvent(event: String) {
    Log.i(TargetActivity.TAG, "$event pkg=$packageName pid=${Process.myPid()}")
}
