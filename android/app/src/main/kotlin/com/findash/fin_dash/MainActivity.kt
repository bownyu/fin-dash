package com.findash.fin_dash

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.ComponentName
import android.content.Intent
import android.content.Context
import android.provider.Settings
import android.service.notification.NotificationListenerService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var voiceBridge: VoiceBridge? = null
    private val ioWorker = Executors.newSingleThreadExecutor()
    override fun provideFlutterEngine(context: Context): FlutterEngine = FinDashEngine.get(context, showApp = true)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        voiceBridge = VoiceBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "findash/payment_notifications")
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences("payment_capture", MODE_PRIVATE)
                val component = ComponentName(this, PaymentNotificationListener::class.java)
                if (call.method == "openSettings") {
                    try {
                        startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                        result.success(null)
                    } catch (_: Exception) { result.error("settings", "无法打开系统通知使用权设置", null) }
                    return@setMethodCallHandler
                }
                ioWorker.execute {
                    try {
                        val inbox = NotificationInbox.get(this)
                        val value: Any? = when (call.method) {
                            "status" -> {
                                val listeners = Settings.Secure.getString(contentResolver, "enabled_notification_listeners") ?: ""
                                val granted = listeners.split(':').any { ComponentName.unflattenFromString(it) == component }
                                mapOf("enabled" to prefs.getBoolean("enabled", false), "granted" to granted,
                                    "connected" to PaymentNotificationListener.connected, "queued" to inbox.count(),
                                    "lastReceived" to prefs.getLong("lastReceived", 0),
                                    "overflow" to prefs.getInt("overflow", 0), "storageError" to prefs.getBoolean("storageError", false))
                            }
                            "setEnabled" -> {
                                val enabled = call.argument<Boolean>("enabled") == true
                                synchronized(inbox) {
                                    check(prefs.edit().putBoolean("enabled", enabled).commit())
                                }
                                if (enabled) NotificationListenerService.requestRebind(component)
                                null
                            }
                            "peek" -> inbox.peek()
                            "ack" -> { inbox.acknowledge(call.argument<List<String>>("ids") ?: emptyList()); null }
                            "clear" -> {
                                inbox.clear()
                                prefs.edit().putInt("overflow", 0).putBoolean("storageError", false).commit()
                                null
                            }
                            else -> throw IllegalArgumentException("未知通知接口")
                        }
                        runOnUiThread { result.success(value) }
                    } catch (_: Exception) {
                        runOnUiThread { result.error("capture", "通知操作失败，请刷新或检查系统设置", null) }
                    }
                }
            }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voiceBridge?.onPermission(requestCode, grantResults)
    }
    override fun onDestroy() { voiceBridge?.destroy(); ioWorker.shutdown(); super.onDestroy() }
}
