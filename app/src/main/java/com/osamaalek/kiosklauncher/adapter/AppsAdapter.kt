package com.osamaalek.kiosklauncher.adapter

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView
import com.osamaalek.kiosklauncher.R
import com.osamaalek.kiosklauncher.model.AppInfo


class AppsAdapter(
    private val list: List<AppInfo>,
    private val onAppClick: (AppInfo) -> Unit,
) : RecyclerView.Adapter<AppsAdapter.ContentHolder>() {

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ContentHolder {
        val view = LayoutInflater.from(parent.context).inflate(R.layout.holder_app, parent, false)
        return ContentHolder(view)
    }

    override fun onBindViewHolder(holder: ContentHolder, position: Int) {
        val app = list[position]
        holder.textView.text = app.label
        holder.imageView.setImageDrawable(app.icon)
        holder.itemView.setOnClickListener { onAppClick(app) }
    }

    override fun getItemCount(): Int {
        return list.size
    }

    class ContentHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
        val imageView: ImageView = itemView.findViewById(R.id.app_icon)
        val textView: TextView = itemView.findViewById(R.id.app_name)
    }

}
