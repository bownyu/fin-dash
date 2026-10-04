package com.findash.fin_dash

import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sqrt

/** Used after manual stop only: prefer quiet boundaries and retain every PCM sample. */
object PcmSegments {
    private const val RATE = 16000

    /** Loudness of one PCM16 buffer, mapping -60..-20 dBFS onto 0..1 for the recording meter. */
    fun level(buffer: ByteArray, count: Int): Float {
        val samples = minOf(count, buffer.size) / 2
        if (samples == 0) return 0f
        var sum = 0.0
        for (i in 0 until samples) {
            val sample = ((buffer[i * 2].toInt() and 255) or (buffer[i * 2 + 1].toInt() shl 8))
                .toShort() / 32768.0
            sum += sample * sample
        }
        val decibels = 20 * log10(maxOf(sqrt(sum / samples), 1e-9))
        return ((decibels + 60) / 40).coerceIn(0.0, 1.0).toFloat()
    }

    fun read(file: File, consume: (FloatArray) -> Boolean) {
        RandomAccessFile(file, "r").use { input ->
            val buffer = ByteArray(RATE * 20 * 2)
            while (input.filePointer < input.length()) {
                val start = input.filePointer
                val count = minOf(buffer.size.toLong(), input.length() - start).toInt()
                input.readFully(buffer, 0, count)
                var end = count / 2
                val samples = FloatArray(end) { i ->
                    ((buffer[i * 2].toInt() and 255) or (buffer[i * 2 + 1].toInt() shl 8))
                        .toShort().toFloat() / 32768f
                }
                if (count == buffer.size && input.filePointer < input.length()) {
                    // Choose the quietest 100 ms window in the last five seconds.
                    var quietest = Float.MAX_VALUE
                    for (offset in RATE * 15 until samples.size - RATE / 10 step RATE / 10) {
                        var energy = 0f
                        for (i in offset until offset + RATE / 10) energy += abs(samples[i])
                        if (energy < quietest) { quietest = energy; end = offset + RATE / 20 }
                    }
                    input.seek(start + end * 2L)
                }
                // Exact digital silence has no transcript; never invent words for an empty buffer.
                var hasSignal = false
                for (i in 0 until end) if (samples[i] != 0f) { hasSignal = true; break }
                if (hasSignal && !consume(samples.copyOf(end))) return
            }
        }
    }
}
