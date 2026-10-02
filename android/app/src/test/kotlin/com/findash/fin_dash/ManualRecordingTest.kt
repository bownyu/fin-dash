package com.findash.fin_dash

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.io.FileOutputStream

class ManualRecordingTest {
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

    @Test fun digitalSilenceNeverReachesTheRecognizer() {
        val file = File.createTempFile("findash-pcm-silence-", ".pcm")
        try {
            file.writeBytes(ByteArray(32000))
            PcmSegments.read(file) { fail("Silence must not yield text"); true }
        } finally { file.delete() }
    }
}
