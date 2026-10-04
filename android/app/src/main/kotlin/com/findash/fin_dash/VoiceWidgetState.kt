package com.findash.fin_dash

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

object VoiceWidgetState {
    fun preferences(context: Context) = context.getSharedPreferences("voice_widget", Context.MODE_PRIVATE)
    fun show(context: Context, id: Int, message: String? = null, text: String? = null,
        phase: String? = null, draft: String? = null, summary: String? = null,
        transaction: String? = null, entryId: String? = null, canConfirm: Boolean? = null,
        clear: Boolean = false, hasAccounts: Boolean? = null, live: String? = null) {
        val edit = preferences(context).edit()
        if (clear) for (key in listOf("draft", "transaction", "summary", "canConfirm")) edit.remove("$key:$id")
        message?.let { edit.putString("status:$id", it) }
        text?.let { edit.putString("text:$id", it) }
        phase?.let { edit.putString("phase:$id", it) }
        draft?.let { edit.putString("draft:$id", it) }
        summary?.let { edit.putString("summary:$id", it) }
        transaction?.let { edit.putString("transaction:$id", it); edit.remove("draft:$id") }
        entryId?.let { edit.putString("entry:$id", it) }
        canConfirm?.let { edit.putBoolean("canConfirm:$id", it) }
        hasAccounts?.let { edit.putBoolean("hasAccounts:$id", it) }
        // Words heard in the current capture; they only become text:$id once recognized.
        live?.let { if (it.isEmpty()) edit.remove("live:$id") else edit.putString("live:$id", it) }
        edit.apply()
        render(context, id)
    }
    fun render(context: Context, id: Int) {
        val prefs = preferences(context)
        val phase = prefs.getString("phase:$id", "idle") ?: "idle"
        val hasDraft = prefs.contains("draft:$id")
        val transfer = try { JSONObject(prefs.getString("draft:$id", "{}") ?: "{}").optJSONObject("fields")?.optString("type") == "transfer" } catch (_: Exception) { false }
        val canConfirm = prefs.getBoolean("canConfirm:$id", false)
        val saved = prefs.contains("transaction:$id")
        val operation = VoiceWidgetFlow.primary(phase, canConfirm, hasDraft)
        val busy = phase in VoiceWidgetFlow.busy
        val views = RemoteViews(context.packageName, R.layout.voice_widget)
        val transcript = prefs.getString("text:$id", "") ?: ""
        val live = if (phase in setOf("starting", "listening", "recognizing"))
            prefs.getString("live:$id", "") ?: "" else ""
        val summary = when {
            live.isNotBlank() -> if (hasDraft) "补充：$live" else live
            hasDraft || saved -> prefs.getString("summary:$id", transcript)
            else -> transcript
        }
        views.setTextViewText(R.id.voice_widget_text,
            if (summary.isNullOrBlank()) "FinDash · 语音记账" else summary.substringBefore('\n'))
        val detail = summary?.substringAfter('\n', "") ?: ""
        views.setTextViewText(R.id.voice_widget_detail, detail)
        views.setViewVisibility(R.id.voice_widget_detail, if (detail.isBlank()) View.GONE else View.VISIBLE)
        views.setTextViewText(R.id.voice_widget_status, prefs.getString("status:$id", "点一下开始 · 说完再点一下"))
        fun action(name: String, request: Int): PendingIntent = PendingIntent.getBroadcast(context, request,
            Intent(context, VoiceWidget::class.java).setAction(name).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        views.setOnClickPendingIntent(R.id.voice_widget_button, action(VoiceWidget.ACTION_PRIMARY, id * 8))
        views.setOnClickPendingIntent(R.id.voice_widget_retry, action(VoiceWidget.ACTION_RETRY, id * 8 + 1))
        views.setOnClickPendingIntent(R.id.voice_widget_undo, action(VoiceWidget.ACTION_UNDO, id * 8 + 2))
        views.setOnClickPendingIntent(R.id.voice_widget_account, action(VoiceWidget.ACTION_ACCOUNT, id * 8 + 3))
        views.setOnClickPendingIntent(R.id.voice_widget_from, action(VoiceWidget.ACTION_FROM_ACCOUNT, id * 8 + 5))
        views.setOnClickPendingIntent(R.id.voice_widget_to, action(VoiceWidget.ACTION_TO_ACCOUNT, id * 8 + 6))
        views.setOnClickPendingIntent(R.id.voice_widget_again, action(VoiceWidget.ACTION_SPEAK, id * 8 + 4))
        views.setBoolean(R.id.voice_widget_button, "setEnabled", operation != null)
        val label = when {
            phase == "listening" -> "结束"
            phase == "starting" -> "启动中"
            phase == "saving" -> "保存中"
            busy -> "识别中"
            canConfirm && hasDraft -> "确认"
            hasDraft -> "补充"
            saved -> "再记"
            else -> "开始"
        }
        views.setTextViewText(R.id.voice_widget_action_label, label)
        views.setContentDescription(R.id.voice_widget_button, label)
        views.setImageViewResource(R.id.voice_widget_button, when {
            phase == "listening" -> R.drawable.ic_voice_stop
            hasDraft && canConfirm -> R.drawable.ic_voice_confirm
            else -> R.drawable.ic_voice_widget
        })
        views.setViewVisibility(R.id.voice_widget_progress, if (busy) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.voice_widget_button, if (busy) View.INVISIBLE else View.VISIBLE)
        val editable = !busy && phase != "listening"
        views.setViewVisibility(R.id.voice_widget_transfer_accounts, if (editable && hasDraft && transfer) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.voice_widget_undo, if (editable && saved) View.VISIBLE else View.GONE)
        views.setBoolean(R.id.voice_widget_account, "setEnabled",
            editable && hasDraft && prefs.getBoolean("hasAccounts:$id", false))
        views.setContentDescription(R.id.voice_widget_account,
            if (hasDraft && transfer) "$summary。点击轮换转账账户组合，可用转出和转入按钮分别切换"
            else if (hasDraft) "$summary。点击切换记账账户" else summary ?: "语音记账")
        views.setViewVisibility(R.id.voice_widget_secondary,
            if (editable && (hasDraft || saved || transcript.isNotBlank())) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.voice_widget_again, if (editable && hasDraft) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.voice_widget_retry,
            if (editable && !saved && !hasDraft && transcript.isNotBlank()) View.VISIBLE else View.GONE)
        AppWidgetManager.getInstance(context).updateAppWidget(id, views)
    }
    fun recover(context: Context, id: Int) {
        val phase = preferences(context).getString("phase:$id", "idle")
        if ((phase in VoiceWidgetFlow.busy || phase == "listening") && WidgetVoiceService.activeWidget != id) {
            show(context, id, "上次操作已中断，内容已保留，请重试", phase = "error")
        } else render(context, id)
    }
}
