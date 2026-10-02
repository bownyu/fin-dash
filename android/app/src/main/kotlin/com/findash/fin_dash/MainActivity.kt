package com.findash.fin_dash

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.content.Context
import android.provider.Settings
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var voiceBridge: VoiceBridge? = null
    private var otaBridge: OtaBridge? = null
    private val ioWorker = Executors.newSingleThreadExecutor()
    override fun provideFlutterEngine(context: Context): FlutterEngine = FinDashEngine.get(context, showApp = true)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        voiceBridge = VoiceBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        otaBridge = OtaBridge(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "findash/payment_notifications")
            .setMethodCallHandler { call, result ->
                val prefs = getSharedPreferences("payment_capture", MODE_PRIVATE)
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
                                val granted = PaymentListenerConnection.granted(this)
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
                                if (enabled) PaymentListenerConnection.reconnect(this, manual = true)
                                null
                            }
                            "reconnect" -> PaymentListenerConnection.reconnect(this, manual = true)
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
    override fun onResume() {
        super.onResume()
        // Best effort only: OEM restrictions must not prevent the app from opening.
        try { PaymentListenerConnection.reconnect(this) } catch (_: Exception) { }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voiceBridge?.onPermission(requestCode, grantResults)
    }
    override fun onDestroy() { otaBridge?.destroy(); voiceBridge?.destroy(); ioWorker.shutdown(); super.onDestroy() }
}
