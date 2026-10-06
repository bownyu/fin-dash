package com.findash.fin_dash

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.Process
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import java.io.File
import java.util.concurrent.ExecutionException
import java.util.concurrent.FutureTask
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Records until manual stop; completed audio segments are transcribed during capture.
 * One warm recognizer is shared by the app and widget and released after 30 idle seconds.
 */
class SpeechCapture(
    context: Context,
    private val onResult: (String) -> Unit,
    private val onError: (String) -> Unit,
    private val onPartial: (String) -> Unit = {},
    private val onState: (String) -> Unit = {},
    private val onLevel: (Float) -> Unit = {}
) {
    companion object {
        private const val SAMPLE_RATE = 16000
        private const val MODEL_DIR = "sensevoice-small"
        // App and desktop widget share one microphone, including while decoding.
        private val active = AtomicReference<SpeechCapture?>(null)
        private val modelLock = Any()
        private var warmRecognizer: FutureTask<OfflineRecognizer>? = null
        private var expiry: ScheduledFuture<*>? = null
        private val cleanup = Executors.newSingleThreadScheduledExecutor { action ->
            Thread(action, "findash-voice-cleanup").apply { isDaemon = true }
        }
        private fun releaseWhenIdle(): Unit = synchronized(modelLock) {
            expiry?.cancel(false)
            expiry = cleanup.schedule({
                synchronized(modelLock) {
                    val task = warmRecognizer
                    if (active.get() != null || task?.isDone == false) {
                        releaseWhenIdle()
                    } else {
                        warmRecognizer = null
                        try { task?.get()?.let { synchronized(it) { it.release() } } }
                        catch (_: Exception) { }
                    }
                }
            }, 30, TimeUnit.SECONDS)
        }
    }
    private val context = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val session = ManualRecordingSession()
    private val audioFinished = AtomicBoolean(false)
    private val audioAvailable = Object()

    fun start() {
        if (!session.start()) return
        if (!active.compareAndSet(null, this)) {
            deliver { onError("另一项语音正在处理，请稍后再试") }
            return
        }
        onState("starting")
        Thread({ captureAndTranscribe() }, "findash-offline-voice").start()
    }

    @SuppressLint("MissingPermission") // VoiceBridge / WidgetPermissionActivity request it first.
    private fun captureAndTranscribe() {
        var pcm: File? = null
        var decoding: FutureTask<String>? = null
        try {
            // Fail explicitly if a broken build omitted the model, without using system/cloud ASR.
            context.assets.openFd("$MODEL_DIR/model.int8.onnx").use { }
            if (session.cancelled) return
            val recognizer = synchronized(modelLock) {
                expiry?.cancel(false)
                warmRecognizer ?: FutureTask { loadRecognizer() }.also {
                    warmRecognizer = it
                    Thread(it, "findash-voice-model").start()
                }
            }
            // Remove recordings left by a killed process before opening this session's file.
            context.cacheDir.listFiles { file -> file.name.startsWith("findash-voice-") &&
                file.name.endsWith(".pcm") }?.forEach { it.delete() }
            pcm = File.createTempFile("findash-voice-", ".pcm", context.cacheDir)
            val recordingFile = pcm
            decoding = FutureTask {
                val ready = try { recognizer.get() } catch (e: ExecutionException) {
                    synchronized(modelLock) {
                        if (warmRecognizer === recognizer) warmRecognizer = null
                    }
                    throw e.cause ?: e
                }
                transcribe(recordingFile, ready)
            }.also {
                Thread(it, "findash-voice-decode").start()
            }
            val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            check(minimum > 0) { "当前设备不支持本地录音，请直接输入记账内容" }
            val recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minimum * 2, 6400))
            try {
                check(recorder.state == AudioRecord.STATE_INITIALIZED) { "无法启动麦克风，请重试" }
                if (session.cancelled) return
                pcm.outputStream().buffered().use { output ->
                    recorder.startRecording()
                    check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                        "麦克风被占用，请关闭其他录音后重试"
                    }
                    if (session.ready()) publish { onState("listening") }
                    val buffer = ByteArray(3200) // 100 ms of mono PCM16, bounded cancellation latency.
                    while (session.recording) {
                        val count = recorder.read(buffer, 0, buffer.size)
                        check(count > 0) { "录音中断，请检查麦克风后重试" }
                        if (!session.cancelled) {
                            output.write(buffer, 0, count)
                            output.flush()
                            synchronized(audioAvailable) { audioAvailable.notifyAll() }
                            val level = PcmSegments.level(buffer, count)
                            publish { onLevel(level) }
                        }
                    }
                }
            } finally {
                if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                    try { recorder.stop() } catch (_: IllegalStateException) { }
                }
                recorder.release()
                audioFinished.set(true)
                synchronized(audioAvailable) { audioAvailable.notifyAll() }
            }
            if (session.cancelled) return
            publish { onState("recognizing") }
            val text = try { decoding.get() } catch (e: ExecutionException) {
                throw e.cause ?: e
            }
            if (text.isBlank()) deliver { onError("没有听清，请再说一次，也可以直接输入") }
            else deliver { onResult(text) }
        } catch (_: SecurityException) {
            deliver { onError("请允许麦克风权限后重试，也可以直接输入记账内容") }
        } catch (_: OutOfMemoryError) {
            deliver { onError("本地识别内存不足，请关闭其他应用后重试") }
        } catch (_: LinkageError) {
            deliver { onError("本地语音组件不可用，请重新安装完整版本") }
        } catch (e: Exception) {
            deliver { onError(if (e is IllegalStateException) e.message ?: "录音未完成，请重试"
                else "本地识别未完成，请重试或直接输入记账内容") }
        } finally {
            audioFinished.set(true)
            synchronized(audioAvailable) { audioAvailable.notifyAll() }
            decoding?.cancel(true)
            pcm?.delete()
            active.compareAndSet(this, null)
            releaseWhenIdle()
        }
    }

    private fun loadRecognizer(): OfflineRecognizer {
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        return OfflineRecognizer(context.assets, OfflineRecognizerConfig(
            modelConfig = OfflineModelConfig(
                senseVoice = OfflineSenseVoiceModelConfig(
                    model = "$MODEL_DIR/model.int8.onnx", language = "zh",
                    useInverseTextNormalization = true),
                tokens = "$MODEL_DIR/tokens.txt", numThreads = 2, provider = "cpu")))
    }

    private fun transcribe(pcm: File, recognizer: OfflineRecognizer): String {
        Process.setThreadPriority(Process.THREAD_PRIORITY_BACKGROUND)
        // Keep long recordings on disk. Segments bound model memory without ending the recording.
        if (session.cancelled) return ""
        val vad = Vad(context.assets, VadModelConfig(sileroVadModelConfig =
            SileroVadModelConfig(model = "$MODEL_DIR/silero_vad.onnx", threshold = 0.35f,
                minSpeechDuration = 0.1f, minSilenceDuration = 0.8f, maxSpeechDuration = 20f)))
        try {
            val text = StringBuilder()
            fun decode(samples: FloatArray) = synchronized(recognizer) {
                if (session.cancelled) return
                val stream = recognizer.createStream()
                try {
                    stream.acceptWaveform(samples, SAMPLE_RATE)
                    recognizer.decode(stream)
                    val result = recognizer.getResult(stream).text
                        .replace(Regex("<\\|[^|]*\\|>"), "").trim()
                    if (result.isNotEmpty()) {
                        text.append(result)
                        val partial = text.toString()
                        publish { onPartial(partial) }
                    }
                } finally { stream.release() }
            }
            fun drain() {
                while (!vad.empty() && !session.cancelled) {
                    decode(vad.front().samples)
                    vad.pop()
                }
            }
            // VAD never controls the microphone; only the user stops capture.
            PcmSegments.readGrowing(pcm, { audioFinished.get() }, { session.cancelled }, {
                synchronized(audioAvailable) {
                    if (!audioFinished.get() && !session.cancelled) audioAvailable.wait(100)
                }
            }) { samples ->
                vad.acceptWaveform(samples)
                drain()
            }
            vad.flush()
            drain()
            return text.toString()
        } finally { vad.release() }
    }

    fun stop() {
        if (session.stop()) onState("recognizing")
    }
    fun cancel() { session.cancel() }
    private fun publish(callback: () -> Unit) {
        handler.post { if (!session.cancelled) callback() }
    }
    private fun deliver(callback: () -> Unit) {
        handler.post { if (session.finish()) callback() }
    }
}
