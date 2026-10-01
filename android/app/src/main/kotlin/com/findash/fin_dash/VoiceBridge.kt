package com.findash.fin_dash

import android.Manifest
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class VoiceBridge(private val activity: FlutterActivity, messenger: BinaryMessenger) {
    companion object { const val AUDIO_PERMISSION = 7132 }
    private val channel = MethodChannel(messenger, "findash/voice")
    private var speech: SpeechCapture? = null
    private var pending: MethodChannel.Result? = null
    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (pending != null) result.error("busy", "正在识别，请稍后重试", null)
                    else {
                        pending = result
                        if (Build.VERSION.SDK_INT >= 23 && activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
                            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), AUDIO_PERMISSION)
                        else startRecognition()
                    }
                }
                "stop" -> { speech?.stop(); result.success(null) }
                "cancel" -> { cancel(); result.success(null) }
                "pinWidget" -> {
                    val manager = AppWidgetManager.getInstance(activity)
                    val supported = Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported
                    if (supported) manager.requestPinAppWidget(ComponentName(activity, VoiceWidget::class.java), null, null)
                    result.success(supported)
                }
                else -> result.notImplemented()
            }
        }
    }
    fun onPermission(requestCode: Int, grantResults: IntArray) {
        if (requestCode != AUDIO_PERMISSION || pending == null) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startRecognition()
        else finish(null, "请允许麦克风权限后重试，也可以直接输入记账内容")
    }
    private fun startRecognition() {
        speech = SpeechCapture(activity, { finish(it, null) }, { finish(null, it) })
        speech!!.start()
    }
    private fun finish(text: String?, error: String?) {
        val result = pending ?: return
        pending = null
        speech = null
        if (error != null) result.error("recognition", error, null) else result.success(text)
    }
    fun cancel() { speech?.cancel(); speech = null; val result = pending; pending = null; result?.success(null) }
    fun destroy() { cancel(); channel.setMethodCallHandler(null) }
}
