package com.findash.fin_dash

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

class WidgetVoiceService : Service() {
    companion object {
        private var instance: WidgetVoiceService? = null
        val activeWidget get() = instance?.activeId ?: AppWidgetManager.INVALID_APPWIDGET_ID
        fun stopRecording(id: Int) {
            if (instance?.activeId == id) instance?.speech?.stop()
        }
        fun cancelRecording(id: Int) {
            if (instance?.activeId == id) instance?.stopSelf()
        }
        fun launch(context: Context, id: Int, operation: String) {
            val intent = Intent(context, WidgetVoiceService::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id).putExtra("operation", operation)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (_: Exception) {
                VoiceWidgetState.show(context, id, "无法启动语音，请重新点击小部件", phase = "error")
            }
        }
    }
    private var speech: SpeechCapture? = null
    private var activeId = AppWidgetManager.INVALID_APPWIDGET_ID
    private val handler = Handler(Looper.getMainLooper())
    private var generation = 0
    private val timeout = Runnable {
        if (activeId != AppWidgetManager.INVALID_APPWIDGET_ID)
            finish(activeId, mapOf("message" to "处理超时，内容已保留，请重试"))
    }
    override fun onCreate() { super.onCreate(); instance = this }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) { stopSelf(startId); return START_NOT_STICKY }
        if (activeId != AppWidgetManager.INVALID_APPWIDGET_ID) {
            if (id != activeId) VoiceWidgetState.show(this, id, "另一项语音正在处理，请稍后再试", phase = "error")
            return START_NOT_STICKY
        }
        activeId = id
        generation++
        val operation = intent?.getStringExtra("operation") ?: "speak"
        val microphone = operation == "speak" || operation == "supplement"
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(
            NotificationChannel("voice_entry", "语音记账", NotificationManager.IMPORTANCE_LOW))
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "voice_entry") else Notification.Builder(this)
        if (microphone) builder.addAction(R.drawable.ic_voice_stop, "结束录音",
            PendingIntent.getBroadcast(this, id, Intent(this, VoiceWidget::class.java)
                .setAction(VoiceWidget.ACTION_PRIMARY)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        val notification = builder.setContentTitle("FinDash 语音记账")
            .setContentText(if (microphone) "正在听，点小部件结束" else "正在处理账单")
            .setSmallIcon(R.drawable.ic_voice_widget).setOngoing(true).build()
        try {
            if (Build.VERSION.SDK_INT >= 34) startForeground(7012, notification,
                if (microphone) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
            else if (Build.VERSION.SDK_INT >= 29) startForeground(7012, notification,
                if (microphone) ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE else 0)
            else startForeground(7012, notification)
        } catch (_: Exception) {
            finish(id, mapOf("message" to "系统未允许启动语音，请重试或在 App 中输入"))
            return START_NOT_STICKY
        }
        val prefs = VoiceWidgetState.preferences(this)
        when (operation) {
            "undo" -> {
                val tx = prefs.getString("transaction:$id", null)
                if (tx == null) finish(id, mapOf("message" to "暂无可撤销账单"))
                else callRuntime(id, mapOf("operation" to "undo", "transaction" to tx))
            }
            "confirm", "account" -> {
                val draft = prefs.getString("draft:$id", null)
                if (draft == null) finish(id, mapOf("message" to "请先说一笔，生成账单"))
                else callRuntime(id, mapOf("operation" to operation, "draft" to draft))
            }
            "retry" -> {
                callRuntime(id, mapOf("operation" to "preview",
                    "text" to (prefs.getString("text:$id", "") ?: ""),
                    "entryId" to (prefs.getString("entry:$id", null) ?: UUID.randomUUID().toString())))
            }
            else -> {
                val previous = if (operation == "supplement") prefs.getString("text:$id", "") ?: "" else ""
                val entry = UUID.randomUUID().toString()
                // Keep previous text until the local model returns a new transcript.
                VoiceWidgetState.show(this, id, "正在启动麦克风…", phase = "starting",
                    entryId = entry, clear = true)
                speech = SpeechCapture(this, { text ->
                    speech = null
                    val combined = if (previous.isEmpty()) text else "$previous；补充：$text"
                    VoiceWidgetState.show(this, id, text = combined)
                    callRuntime(id, mapOf("operation" to "preview", "text" to combined, "entryId" to entry))
                }, { message ->
                    speech = null
                    finish(id, mapOf("message" to message))
                }, { text ->
                    VoiceWidgetState.show(this, id, text = if (previous.isEmpty()) text else "$previous；补充：$text")
                }, { state ->
                    VoiceWidgetState.show(this, id, when (state) {
                        "listening" -> "正在录音 · 点一下结束"
                        "recognizing" -> "正在本地转文字…"
                        else -> "正在启动麦克风…"
                    }, phase = state)
                })
                speech!!.start()
            }
        }
        return START_NOT_STICKY
    }
    private fun callRuntime(id: Int, request: Map<String, Any>) {
        val token = generation
        val saving = request["operation"] in listOf("confirm", "undo")
        VoiceWidgetState.show(this, id, if (saving) "正在保存…" else "AI 正在整理账单…",
            phase = if (saving) "saving" else "parsing")
        handler.removeCallbacks(timeout)
        handler.postDelayed(timeout, 90000)
        try {
            FinDashEngine.whenReady(this) { engine ->
                if (token != generation || activeId != id) return@whenReady
                MethodChannel(engine.dartExecutor.binaryMessenger, "findash/voice_widget").invokeMethod("record", request, object : MethodChannel.Result {
                    private fun done(result: Map<*, *>) {
                        if (token == generation && activeId == id) finish(id, result)
                    }
                    override fun success(result: Any?) = done(result as? Map<*, *> ?: mapOf("message" to "没有收到结果，请重试"))
                    override fun error(code: String, message: String?, details: Any?) = done(mapOf("message" to "暂时不可用，内容已保留，请重试"))
                    override fun notImplemented() = done(mapOf("message" to "账本尚未就绪，请重试"))
                })
            }
        } catch (_: Exception) { finish(id, mapOf("message" to "账本尚未就绪，请重试")) }
    }
    private fun finish(id: Int, result: Map<*, *>) {
        handler.removeCallbacks(timeout)
        val tx = result["transaction"] as? Map<*, *>
        val draft = result["draft"] as? Map<*, *>
        val undone = result["undone"] == true
        VoiceWidgetState.show(this, id, result["message"]?.toString() ?: "未完成，请重试",
            text = if (undone) "" else null,
            phase = when { undone -> "idle"; tx != null -> "saved"; draft != null -> "review"; else -> "error" },
            transaction = tx?.let { JSONObject(it).toString() },
            draft = draft?.let { JSONObject(it).toString() },
            summary = result["summary"]?.toString(),
            canConfirm = result["canConfirm"] as? Boolean,
            hasAccounts = result["hasAccounts"] as? Boolean,
            clear = undone)
        activeId = AppWidgetManager.INVALID_APPWIDGET_ID
        generation++
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onDestroy() {
        generation++
        handler.removeCallbacks(timeout)
        speech?.cancel()
        if (activeId != AppWidgetManager.INVALID_APPWIDGET_ID)
            VoiceWidgetState.show(this, activeId, "语音已中断，内容已保留，请重试", phase = "error")
        if (instance === this) instance = null
        super.onDestroy()
    }
}
