package com.findash.fin_dash

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

object VoiceWidgetState {
    /** Keys a new recording drops; every per-widget key ends with ":<widget id>". */
    private val draftKeys = listOf("draft", "transaction", "summary", "canConfirm", "openApp")
    private enum class Size(val layout: Int) {
        SMALL(R.layout.voice_widget_small), MEDIUM(R.layout.voice_widget_medium), LARGE(R.layout.voice_widget)
    }
    private fun size(manager: AppWidgetManager, id: Int) = when (manager.getAppWidgetInfo(id)?.provider?.className) {
        VoiceWidgetSmall::class.java.name -> Size.SMALL
        VoiceWidgetMedium::class.java.name -> Size.MEDIUM
        else -> Size.LARGE
    }
    fun preferences(context: Context) = context.getSharedPreferences("voice_widget", Context.MODE_PRIVATE)
    /** A saved bill keeps its draft for account changes; only an unsaved draft is under review. */
    fun reviewing(prefs: SharedPreferences, id: Int) = prefs.contains("draft:$id") && !prefs.contains("transaction:$id")
    fun appIntent(context: Context): Intent = Intent(context, MainActivity::class.java)
        .setAction(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    fun show(context: Context, id: Int, message: String? = null, text: String? = null,
        phase: String? = null, draft: String? = null, summary: String? = null,
        transaction: String? = null, entryId: String? = null, canConfirm: Boolean? = null,
        clear: Boolean = false, hasAccounts: Boolean? = null, live: String? = null,
        openApp: Boolean? = null) {
        val edit = preferences(context).edit()
        if (clear) for (key in draftKeys) edit.remove("$key:$id")
        message?.let { edit.putString("status:$id", it) }
        text?.let { edit.putString("text:$id", it) }
        phase?.let {
            edit.putString("phase:$id", it)
            if (it == "listening") edit.putLong("listenStart:$id", SystemClock.elapsedRealtime())
        }
        draft?.let { edit.putString("draft:$id", it) }
        summary?.let { edit.putString("summary:$id", it) }
        transaction?.let { edit.putString("transaction:$id", it) }
        entryId?.let { edit.putString("entry:$id", it) }
        canConfirm?.let { edit.putBoolean("canConfirm:$id", it) }
        hasAccounts?.let { edit.putBoolean("hasAccounts:$id", it) }
        openApp?.let { edit.putBoolean("openApp:$id", it) }
        // Words heard in the current capture; they only become text:$id once recognized.
        live?.let { if (it.isEmpty()) edit.remove("live:$id") else edit.putString("live:$id", it) }
        edit.apply()
        render(context, id)
    }
    fun render(context: Context, id: Int) {
        val prefs = preferences(context)
        val phase = prefs.getString("phase:$id", "idle") ?: "idle"
        val hasDraft = prefs.contains("draft:$id")
        val saved = prefs.contains("transaction:$id")
        val reviewing = reviewing(prefs, id)
        val openApp = prefs.getBoolean("openApp:$id", false)
        val transfer = try { JSONObject(prefs.getString("draft:$id", "{}") ?: "{}").optJSONObject("fields")?.optString("type") == "transfer" } catch (_: Exception) { false }
        val canConfirm = prefs.getBoolean("canConfirm:$id", false)
        val operation = VoiceWidgetFlow.primary(phase, canConfirm, reviewing, openApp)
        val busy = phase in VoiceWidgetFlow.busy
        val listening = phase == "listening"
        val editable = !busy && !listening
        val manager = AppWidgetManager.getInstance(context)
        val size = size(manager, id)
        val views = RemoteViews(context.packageName, size.layout)
        val transcript = prefs.getString("text:$id", "") ?: ""
        val live = if (phase in setOf("starting", "listening", "recognizing"))
            prefs.getString("live:$id", "") ?: "" else ""
        val summary = when {
            live.isNotBlank() -> if (reviewing) "补充：$live" else live
            hasDraft || saved -> prefs.getString("summary:$id", transcript)
            else -> transcript
        }
        val status = prefs.getString("status:$id", null) ?: context.getString(
            if (size == Size.MEDIUM) R.string.voice_widget_hint_short else R.string.voice_widget_hint)
        // The launcher ticks the timer itself; recording sends no per-second updates.
        views.setChronometer(R.id.voice_widget_timer,
            prefs.getLong("listenStart:$id", SystemClock.elapsedRealtime()), null, listening)
        views.setViewVisibility(R.id.voice_widget_timer, if (listening) View.VISIBLE else View.GONE)
        fun action(name: String, request: Int): PendingIntent = PendingIntent.getBroadcast(context, request,
            Intent(context, VoiceWidget::class.java).setAction(name).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val app = PendingIntent.getActivity(context, id * 8 + 7, appIntent(context),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val primary = action(VoiceWidget.ACTION_PRIMARY, id * 8)
        val switchable = editable && hasDraft && !openApp && prefs.getBoolean("hasAccounts:$id", false)
        val button = if (operation == "open") app else primary
        views.setOnClickPendingIntent(R.id.voice_widget_button, button)
        // While recording the whole card stops it. Otherwise the 1×1 card acts as its button,
        // and larger cards change accounts or open the app.
        views.setOnClickPendingIntent(R.id.voice_widget_body, when {
            listening -> primary
            busy -> null
            size == Size.SMALL -> button
            switchable -> action(VoiceWidget.ACTION_ACCOUNT, id * 8 + 3)
            else -> app
        })
        views.setBoolean(R.id.voice_widget_button, "setEnabled", operation != null)
        val label = when {
            listening -> "结束"
            phase == "starting" -> "启动中"
            phase == "saving" -> "保存中"
            busy -> "识别中"
            operation == "open" -> "去核对"
            operation == "confirm" -> "确认"
            reviewing -> "补充"
            saved -> "再记"
            else -> "开始"
        }
        views.setContentDescription(R.id.voice_widget_button, label)
        views.setImageViewResource(R.id.voice_widget_button, when {
            listening -> R.drawable.ic_voice_stop
            operation == "confirm" -> R.drawable.ic_voice_confirm
            operation == "open" -> R.drawable.ic_voice_open
            else -> R.drawable.ic_voice_widget
        })
        views.setInt(R.id.voice_widget_button, "setBackgroundResource", when {
            listening -> R.drawable.voice_widget_action_recording
            operation == "confirm" -> R.drawable.voice_widget_action_confirm
            else -> R.drawable.voice_widget_action_background
        })
        views.setViewVisibility(R.id.voice_widget_progress, if (busy) View.VISIBLE else View.GONE)
        views.setViewVisibility(R.id.voice_widget_button, if (busy) View.INVISIBLE else View.VISIBLE)
        if (size == Size.SMALL) {
            // One word under the button; the timer takes its place while recording.
            val brief = when {
                !editable || reviewing -> label
                saved -> "已保存"
                phase == "error" -> "未完成"
                else -> "记一笔"
            }
            views.setTextViewText(R.id.voice_widget_action_label, brief)
            views.setViewVisibility(R.id.voice_widget_action_label, if (listening) View.GONE else View.VISIBLE)
            views.setContentDescription(R.id.voice_widget_body, "$status。$brief")
            manager.updateAppWidget(id, views)
            return
        }
        views.setTextViewText(R.id.voice_widget_status, status)
        views.setTextViewText(R.id.voice_widget_text,
            if (summary.isNullOrBlank()) context.getString(R.string.voice_widget_idle) else summary.substringBefore('\n'))
        val detail = summary?.substringAfter('\n', "") ?: ""
        views.setTextViewText(R.id.voice_widget_detail, detail)
        views.setViewVisibility(R.id.voice_widget_detail, if (detail.isBlank()) View.GONE else View.VISIBLE)
        views.setContentDescription(R.id.voice_widget_body, when {
            listening -> "$summary。点击结束录音"
            switchable && transfer -> "$summary。点击轮换转账账户组合" +
                if (size == Size.LARGE) "，可用转出和转入按钮分别切换" else ""
            switchable -> "$summary。点击切换记账账户"
            else -> "${summary ?: ""}。点击打开 FinDash"
        })
        // Undo, redo and retry are mutually exclusive; only 4×2 has room for the transfer sides.
        val chips = buildMap {
            put(R.id.voice_widget_undo, editable && saved)
            put(R.id.voice_widget_again, editable && reviewing)
            put(R.id.voice_widget_retry, editable && !saved && !hasDraft && transcript.isNotBlank())
            if (size == Size.LARGE) {
                put(R.id.voice_widget_from, switchable && transfer)
                put(R.id.voice_widget_to, switchable && transfer)
            }
        }
        views.setOnClickPendingIntent(R.id.voice_widget_retry, action(VoiceWidget.ACTION_RETRY, id * 8 + 1))
        views.setOnClickPendingIntent(R.id.voice_widget_undo, action(VoiceWidget.ACTION_UNDO, id * 8 + 2))
        views.setOnClickPendingIntent(R.id.voice_widget_again, action(VoiceWidget.ACTION_SPEAK, id * 8 + 4))
        chips.forEach { (view, shown) -> views.setViewVisibility(view, if (shown) View.VISIBLE else View.GONE) }
        if (size == Size.LARGE) {
            views.setOnClickPendingIntent(R.id.voice_widget_from, action(VoiceWidget.ACTION_FROM_ACCOUNT, id * 8 + 5))
            views.setOnClickPendingIntent(R.id.voice_widget_to, action(VoiceWidget.ACTION_TO_ACCOUNT, id * 8 + 6))
            views.setTextViewText(R.id.voice_widget_action_label, label)
            views.setViewVisibility(R.id.voice_widget_actions, if (chips.values.any { it }) View.VISIBLE else View.GONE)
        }
        manager.updateAppWidget(id, views)
    }
    fun recover(context: Context, id: Int) {
        val phase = preferences(context).getString("phase:$id", "idle")
        if ((phase in VoiceWidgetFlow.busy || phase == "listening") && WidgetVoiceService.activeWidget != id) {
            show(context, id, "上次操作已中断，内容已保留，请重试", phase = "error")
        } else render(context, id)
    }
}
