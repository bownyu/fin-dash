package com.findash.fin_dash

import android.Manifest
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

class VoiceWidget : AppWidgetProvider() {
    companion object {
        const val ACTION_SPEAK = "com.findash.fin_dash.widget.SPEAK"
        const val ACTION_RETRY = "com.findash.fin_dash.widget.RETRY"
        const val ACTION_UNDO = "com.findash.fin_dash.widget.UNDO"
    }
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { VoiceWidgetState.show(context, it) }
    }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val operation = when (intent.action) { ACTION_SPEAK -> "speak"; ACTION_RETRY -> "retry"; ACTION_UNDO -> "undo"; else -> return }
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
        if (Build.VERSION.SDK_INT >= 23 && context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            context.startActivity(Intent(context, WidgetPermissionActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id).putExtra("operation", operation))
        } else WidgetVoiceService.launch(context, id, operation)
    }
    override fun onDeleted(context: Context, ids: IntArray) {
        val edit = VoiceWidgetState.preferences(context).edit()
        for (id in ids) for (key in listOf("status", "text", "transaction", "clarification", "entry", "recordable")) edit.remove("$key:$id")
        edit.apply()
    }
}
