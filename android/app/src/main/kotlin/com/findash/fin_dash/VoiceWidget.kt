package com.findash.fin_dash

import android.Manifest
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle

/** 4×2. Every size shares this flow and per-widget state; button intents always come here. */
open class VoiceWidget : AppWidgetProvider() {
    companion object {
        const val ACTION_PRIMARY = "com.findash.fin_dash.widget.PRIMARY"
        const val ACTION_SPEAK = "com.findash.fin_dash.widget.SPEAK"
        const val ACTION_RETRY = "com.findash.fin_dash.widget.RETRY"
        const val ACTION_UNDO = "com.findash.fin_dash.widget.UNDO"
        const val ACTION_ACCOUNT = "com.findash.fin_dash.widget.ACCOUNT"
        const val ACTION_FROM_ACCOUNT = "com.findash.fin_dash.widget.FROM_ACCOUNT"
        const val ACTION_TO_ACCOUNT = "com.findash.fin_dash.widget.TO_ACCOUNT"
    }
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { VoiceWidgetState.recover(context, it) }
    }
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) {
        VoiceWidgetState.recover(context, id)
    }
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        val id = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) return
        val prefs = VoiceWidgetState.preferences(context)
        val operation = when (intent.action) {
            ACTION_PRIMARY -> VoiceWidgetFlow.primary(prefs.getString("phase:$id", "idle") ?: "idle",
                prefs.getBoolean("canConfirm:$id", false), VoiceWidgetState.reviewing(prefs, id),
                prefs.getBoolean("openApp:$id", false)) ?: return
            ACTION_SPEAK -> "speak"
            ACTION_RETRY -> "retry"
            ACTION_UNDO -> "undo"
            ACTION_ACCOUNT -> "account"
            ACTION_FROM_ACCOUNT -> "fromAccount"
            ACTION_TO_ACCOUNT -> "toAccount"
            else -> return
        }
        if (operation == "stop") { WidgetVoiceService.stopRecording(id); return }
        // The rendered button opens the app directly; this only covers a stale layout.
        if (operation == "open") {
            try { context.startActivity(VoiceWidgetState.appIntent(context)) } catch (_: Exception) { }
            return
        }
        val microphone = operation == "speak" || operation == "supplement"
        if (microphone && Build.VERSION.SDK_INT >= 23 &&
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            context.startActivity(Intent(context, WidgetPermissionActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                .putExtra("operation", operation))
        } else WidgetVoiceService.launch(context, id, operation)
    }
    override fun onDeleted(context: Context, ids: IntArray) {
        ids.forEach { WidgetVoiceService.cancelRecording(it) }
        val prefs = VoiceWidgetState.preferences(context)
        val edit = prefs.edit()
        val suffixes = ids.map { ":$it" }
        for (key in prefs.all.keys) if (suffixes.any { key.endsWith(it) }) edit.remove(key)
        edit.apply()
    }
}

/** 2×2: summary, one action and the button; layout chosen in [VoiceWidgetState.render]. */
class VoiceWidgetMedium : VoiceWidget()

/** 1×1: the button alone. */
class VoiceWidgetSmall : VoiceWidget()
