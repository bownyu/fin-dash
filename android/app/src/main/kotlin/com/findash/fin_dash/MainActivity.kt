package com.findash.fin_dash

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.content.Context
import android.net.Uri
import android.os.PowerManager
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
                if (call.method in setOf("openSettings", "openBatterySettings", "openAppSettings")) {
                    try {
                        val intent = when (call.method) {
                            "openBatterySettings" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                            "openAppSettings" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            else -> Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                        }
                        try { startActivity(intent) }
                        catch (_: android.content.ActivityNotFoundException) {
                            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        }
                        result.success(null)
                    } catch (_: Exception) { result.error("settings", "无法打开系统设置，请从手机设置进入 FinDash 应用详情", null) }
                    return@setMethodCallHandler
                }
                ioWorker.execute {
                    try {
                        val capture = PaymentCaptureClient(this)
                        val value: Any? = when (call.method) {
                            "status" -> {
                                @Suppress("UNCHECKED_CAST")
                                val status = capture.call("status") as Map<String, Any?>
                                status + ("batteryUnrestricted" to getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(packageName))
                            }
                            "setEnabled" -> capture.call("setEnabled", mapOf("enabled" to (call.argument<Boolean>("enabled") == true)))
                            "reconnect" -> capture.call("reconnect", mapOf("manual" to true))
                            "peek" -> capture.call("peek")
                            "ack" -> capture.call("ack", mapOf("ids" to call.argument<List<String>>("ids")))
                            "clear" -> capture.call("clear")
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
        ioWorker.execute {
            try { PaymentCaptureClient(applicationContext).call("reconnect") } catch (_: Exception) { }
        }
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voiceBridge?.onPermission(requestCode, grantResults)
    }
    override fun onDestroy() { otaBridge?.destroy(); voiceBridge?.destroy(); ioWorker.shutdown(); super.onDestroy() }
}
