package com.findash.fin_dash

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews

object VoiceWidgetState {
    fun preferences(context: Context) = context.getSharedPreferences("voice_widget", Context.MODE_PRIVATE)
    fun show(context: Context, id: Int, message: String? = null, text: String? = null,
        transaction: String? = null, clearTransaction: Boolean = false, clarification: Boolean? = null, entryId: String? = null, recordable: Boolean? = null) {
        val prefs = preferences(context)
        val edit = prefs.edit()
        message?.let { edit.putString("status:$id", it) }
        text?.let { edit.putString("text:$id", it) }
        entryId?.let { edit.putString("entry:$id", it) }
        transaction?.let { edit.putString("transaction:$id", it) }
        if (clearTransaction) edit.remove("transaction:$id")
        clarification?.let { edit.putBoolean("clarification:$id", it) }
        recordable?.let { edit.putBoolean("recordable:$id", it) }
        edit.apply()
        val views = RemoteViews(context.packageName, R.layout.voice_widget)
        views.setTextViewText(R.id.voice_widget_status, prefs.getString("status:$id", "点麦克风，说出用途、金额和账户"))
        views.setTextViewText(R.id.voice_widget_text, prefs.getString("text:$id", ""))
        fun action(name: String, request: Int): PendingIntent = PendingIntent.getBroadcast(context, request,
            Intent(context, VoiceWidget::class.java).setAction(name).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        views.setOnClickPendingIntent(R.id.voice_widget_button, action(VoiceWidget.ACTION_SPEAK, id * 3))
        views.setOnClickPendingIntent(R.id.voice_widget_retry, action(VoiceWidget.ACTION_RETRY, id * 3 + 1))
        views.setOnClickPendingIntent(R.id.voice_widget_undo, action(VoiceWidget.ACTION_UNDO, id * 3 + 2))
        val saved = prefs.getString("transaction:$id", null) != null
        views.setViewVisibility(R.id.voice_widget_undo, if (saved) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.voice_widget_retry, if (!saved && prefs.getBoolean("recordable:$id", false)) View.VISIBLE else View.GONE)
        AppWidgetManager.getInstance(context).updateAppWidget(id, views)
    }
}
