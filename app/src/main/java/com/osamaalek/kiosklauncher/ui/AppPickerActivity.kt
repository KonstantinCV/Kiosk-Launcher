package com.osamaalek.kiosklauncher.ui

import android.os.Bundle
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.osamaalek.kiosklauncher.R
import com.osamaalek.kiosklauncher.adapter.AppsAdapter
import com.osamaalek.kiosklauncher.util.AppsUtil
import com.osamaalek.kiosklauncher.util.LoaderConfig

/** Lets the operator pick which app the loader keeps running. */
class AppPickerActivity : LoaderActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_app_picker)

        val recyclerView: RecyclerView = findViewById(R.id.recyclerView_apps)
        recyclerView.layoutManager = GridLayoutManager(this, 4)
        recyclerView.setHasFixedSize(true)
        recyclerView.adapter = AppsAdapter(AppsUtil.getAllApps(this)) { app ->
            LoaderConfig(this).targetPackage = app.packageName
            finish()
        }
    }
}
