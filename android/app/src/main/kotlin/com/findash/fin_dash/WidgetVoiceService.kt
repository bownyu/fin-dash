package com.findash.fin_dash

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.UUID

class WidgetVoiceService : Service() {
    companion object {
        fun launch(context: Context, id: Int, operation: String) {
            val intent = Intent(context, WidgetVoiceService::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id).putExtra("operation", operation)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (_: Exception) { VoiceWidgetState.show(context, id, "无法启动语音，请重新点击小部件") }
        }
    }
    private var speech: SpeechCapture? = null
    private var activeId = AppWidgetManager.INVALID_APPWIDGET_ID
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
            ?: AppWidgetManager.INVALID_APPWIDGET_ID
        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) { stopSelf(); return START_NOT_STICKY }
        if (activeId != AppWidgetManager.INVALID_APPWIDGET_ID) {
            if (id == activeId) speech?.stop()
            else VoiceWidgetState.show(this, id, "另一项语音正在处理，请稍后再试")
            return START_NOT_STICKY
        }
        activeId = id
        val notificationManager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) notificationManager.createNotificationChannel(
            NotificationChannel("voice_entry", "语音记账", NotificationManager.IMPORTANCE_LOW))
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "voice_entry") else Notification.Builder(this)
        val notification = builder.setContentTitle("FinDash 语音记账").setContentText("正在处理桌面小部件的记账请求")
            .setSmallIcon(R.drawable.ic_voice_widget).setOngoing(true).build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(7012, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            else startForeground(7012, notification)
        } catch (_: Exception) { VoiceWidgetState.show(this, id, "麦克风暂不可用，请重新点击小部件"); stopSelf(); return START_NOT_STICKY }
        val prefs = VoiceWidgetState.preferences(this)
        val operation = intent?.getStringExtra("operation") ?: "speak"
        if (operation == "undo") {
            val transaction = prefs.getString("transaction:$id", null)
            if (transaction == null) { finish(id, mapOf("success" to false, "message" to "暂无可撤销的账单")); return START_NOT_STICKY }
            callRuntime(id, mapOf("operation" to "undo", "transaction" to transaction))
        } else if (operation == "retry") {
            val text = prefs.getString("text:$id", "") ?: ""
            val entryId = prefs.getString("entry:$id", null) ?: UUID.randomUUID().toString()
            callRuntime(id, mapOf("operation" to "record", "text" to text, "entryId" to entryId))
        } else {
            val previous = if (prefs.getBoolean("clarification:$id", false)) prefs.getString("text:$id", "") ?: "" else ""
            val entryId = UUID.randomUUID().toString()
            VoiceWidgetState.show(this, id, "正在听…再点麦克风结束", previous, clearTransaction = true, entryId = entryId, recordable = false)
            speech = SpeechCapture(this, { text ->
                speech = null
                val combined = if (previous.isEmpty()) text else "$previous；补充：$text"
                VoiceWidgetState.show(this, id, "正在记账…", combined, recordable = true)
                callRuntime(id, mapOf("operation" to "record", "text" to combined, "entryId" to entryId))
            }, { message -> speech = null; finish(id, mapOf("success" to false, "message" to message)) },
                { text -> VoiceWidgetState.show(this, id, text = if (previous.isEmpty()) text else "$previous；补充：$text") })
            speech!!.start()
        }
        return START_NOT_STICKY
    }
    private fun callRuntime(id: Int, request: Map<String, Any>) {
        VoiceWidgetState.show(this, id, if (request["operation"] == "undo") "正在撤销…" else "正在记账…")
        FinDashEngine.whenReady(this) { engine ->
            MethodChannel(engine.dartExecutor.binaryMessenger, "findash/voice_widget").invokeMethod("record", request, object : MethodChannel.Result {
                override fun success(result: Any?) = finish(id, result as? Map<*, *> ?: mapOf("success" to false, "message" to "没有收到结果，请重试"))
                override fun error(code: String, message: String?, details: Any?) = finish(id, mapOf("success" to false, "message" to "记账暂不可用，请重试"))
                override fun notImplemented() = finish(id, mapOf("success" to false, "message" to "记账尚未就绪，请重试"))
            })
        }
    }
    private fun finish(id: Int, result: Map<*, *>) {
        val transaction = result["transaction"] as? Map<*, *>
        VoiceWidgetState.show(this, id, result["message"]?.toString() ?: "记账未完成，请重试",
            text = if (result["undone"] == true) "" else null,
            transaction = transaction?.let { JSONObject(it).toString() },
            clearTransaction = result["undone"] == true,
            recordable = if (result["undone"] == true) false else null,
            clarification = result["needsClarification"] == true)
        activeId = AppWidgetManager.INVALID_APPWIDGET_ID
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onDestroy() { speech?.cancel(); super.onDestroy() }
}
