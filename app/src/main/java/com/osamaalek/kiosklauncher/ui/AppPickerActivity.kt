package com.osamaalek.kiosklauncher.ui

import android.os.Bundle
import android.view.View
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.osamaalek.kiosklauncher.R
import com.osamaalek.kiosklauncher.adapter.AppsAdapter
import com.osamaalek.kiosklauncher.util.AppsUtil
import com.osamaalek.kiosklauncher.util.LoaderConfig

/**
 * Lets the operator pick which app the loader keeps running: a scrolling list of every launchable
 * app, Quest VR apps and sideloaded (Unknown Sources) apps included. MainActivity opens it by
 * itself while no installed app is set.
 */
class AppPickerActivity : LoaderActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_app_picker)

        val config = LoaderConfig(this)
        val apps = AppsUtil.getAllApps(this)
        findViewById<TextView>(R.id.text_picker_empty).visibility = if (apps.isEmpty()) View.VISIBLE else View.GONE

        val recyclerView: RecyclerView = findViewById(R.id.recyclerView_apps)
        recyclerView.layoutManager = LinearLayoutManager(this)
        recyclerView.setHasFixedSize(true)
        recyclerView.adapter = AppsAdapter(apps, config.targetPackage) { app ->
            config.targetPackage = app.packageName
            finish()
        }
    }
}
