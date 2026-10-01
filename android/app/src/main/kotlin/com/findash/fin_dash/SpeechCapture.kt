package com.findash.fin_dash

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer

class SpeechCapture(private val context: Context, private val onResult: (String) -> Unit,
    private val onError: (String) -> Unit, private val onPartial: (String) -> Unit = {}) {
    private var recognizer: SpeechRecognizer? = null
    private val handler = Handler(Looper.getMainLooper())
    private var finished = false
    private val timeout = Runnable { fail("语音识别超时，请重试") }
    fun start() {
        if (!SpeechRecognizer.isRecognitionAvailable(context)) { fail("系统未安装语音识别服务"); return }
        try {
            recognizer = SpeechRecognizer.createSpeechRecognizer(context)
            recognizer!!.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) {}
                override fun onBeginningOfSpeech() {}
                override fun onRmsChanged(rmsdB: Float) {}
                override fun onBufferReceived(buffer: ByteArray?) {}
                override fun onEndOfSpeech() {}
                override fun onEvent(eventType: Int, params: Bundle?) {}
                override fun onPartialResults(results: Bundle?) {
                    if (!finished) results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()?.let(onPartial)
                }
                override fun onResults(results: Bundle?) {
                    val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
                    if (text.isNullOrBlank()) fail("没有听清，请再说一次")
                    else if (!finished) { release(); onResult(text) }
                }
                override fun onError(error: Int) = fail(when (error) {
                    SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "麦克风权限未开启"
                    SpeechRecognizer.ERROR_NETWORK, SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "语音网络不可用，请重试"
                    SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "没有听清，请再说一次"
                    SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "语音服务忙，请稍后重试"
                    else -> "语音识别失败，请重试"
                })
            })
            handler.postDelayed(timeout, 30000)
            recognizer!!.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, "zh-CN")
                putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            })
        } catch (_: Exception) { fail("无法启动系统语音识别，请重试") }
    }
    fun stop() { recognizer?.stopListening() }
    fun cancel() { release() }
    private fun fail(message: String) { if (!finished) { release(); onError(message) } }
    private fun release() {
        if (finished) return
        finished = true
        handler.removeCallbacks(timeout)
        val previous = recognizer
        recognizer = null
        previous?.destroy()
    }
}
