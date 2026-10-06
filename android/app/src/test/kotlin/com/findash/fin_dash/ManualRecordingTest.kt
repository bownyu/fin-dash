package com.findash.fin_dash

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream

class ManualRecordingTest {
    @Test fun growingAudioDecodesBeforeStopAndPadsOnlyItsLastWindow() {
        val file = File.createTempFile("findash-growing-pcm-", ".pcm")
        try {
            var done = false
            var writes = 0
            val windows = mutableListOf<FloatArray>()
            PcmSegments.readGrowing(file, { done }, { false }, {
                FileOutputStream(file, true).use { output ->
                    val count = if (writes++ == 0) 512 else 7
                    repeat(count) { output.write(1); output.write(0) }
                }
                if (writes == 2) done = true
            }) { samples ->
                if (windows.isEmpty()) assertFalse(done)
                windows.add(samples)
            }
            assertEquals(2, windows.size)
            assertTrue(windows[0].all { it == 1 / 32768f })
            assertTrue(windows[1].take(7).all { it == 1 / 32768f })
            assertTrue(windows[1].drop(7).all { it == 0f })
        } finally { file.delete() }
    }
    @Test fun onlyManualStopCompletesRecording() {
        val session = ManualRecordingSession()
        assertTrue(session.start())
        assertTrue(session.ready())
        assertFalse(session.start())
        assertTrue(session.recording)
        assertTrue(session.stop())
        assertFalse(session.recording)
        assertFalse(session.stop())
        assertTrue(session.finish())
        assertFalse(session.finish())
    }

    @Test fun cancellationPreventsLateResultsAndStartup() {
        for (started in listOf(false, true)) {
            val session = ManualRecordingSession()
            session.start()
            if (started) session.ready()
            session.cancel()
            assertFalse(session.ready())
            assertFalse(session.stop())
            assertFalse(session.finish())
            assertTrue(session.cancelled)
        }
    }

    @Test fun stopDuringStartupCannotTurnMicrophoneBackOn() {
        val session = ManualRecordingSession()
        session.start()
        assertTrue(session.stop())
        assertFalse(session.ready())
        assertFalse(session.recording)
    }

    @Test fun longAudioKeepsSamplesAcrossQuietBoundaries() {
        val file = File.createTempFile("findash-pcm-test-", ".pcm")
        try {
            val count = 16000 * 47
            FileOutputStream(file).buffered().use { output ->
                for (i in 0 until count) {
                    val value = if (i in 16000 * 17 until 16000 * 18) 0 else (i % 60000 - 30000)
                    output.write(value and 255)
                    output.write((value shr 8) and 255)
                }
            }
            var index = 0
            PcmSegments.read(file) { samples ->
                assertTrue(samples.size <= 16000 * 20)
                for (sample in samples) {
                    val expected = if (index in 16000 * 17 until 16000 * 18) 0 else (index % 60000 - 30000)
                    assertEquals(expected / 32768f, sample, 0f)
                    index++
                }
                true
            }
            assertEquals(count, index)
        } finally { file.delete() }
    }

    @Test fun recordingLevelFollowsLoudness() {
        fun buffer(amplitude: Int) = ByteArray(3200).also { bytes ->
            for (i in 0 until 1600) {
                val value = if (i % 2 == 0) amplitude else -amplitude
                bytes[i * 2] = (value and 255).toByte()
                bytes[i * 2 + 1] = ((value shr 8) and 255).toByte()
            }
        }
        assertEquals(0f, PcmSegments.level(ByteArray(3200), 3200), 0f)
        assertEquals(0f, PcmSegments.level(buffer(20), 0), 0f)
        val quiet = PcmSegments.level(buffer(30), 3200)    // about -61 dBFS
        val speech = PcmSegments.level(buffer(2000), 3200) // about -24 dBFS
        assertEquals(0f, quiet, 0f)
        assertTrue(speech > .8f && speech < 1f)
        assertEquals(1f, PcmSegments.level(buffer(32000), 3200), 0f)
        // A short final read only measures the bytes actually recorded.
        assertEquals(speech, PcmSegments.level(buffer(2000).copyOf(6400), 3200), 0f)
    }

    @Test fun digitalSilenceNeverReachesTheRecognizer() {
        val file = File.createTempFile("findash-pcm-silence-", ".pcm")
        try {
            file.writeBytes(ByteArray(32000))
            PcmSegments.read(file) { fail("Silence must not yield text"); true }
        } finally { file.delete() }
    }
}
