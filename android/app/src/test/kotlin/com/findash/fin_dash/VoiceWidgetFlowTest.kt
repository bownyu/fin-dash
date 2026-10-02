package com.findash.fin_dash

import org.junit.Assert.*
import org.junit.Test

class VoiceWidgetFlowTest {
    @Test fun recordReviewConfirmFlow() {
        assertEquals("speak", VoiceWidgetFlow.primary("idle", false, false))
        assertEquals("stop", VoiceWidgetFlow.primary("listening", false, false))
        assertEquals("confirm", VoiceWidgetFlow.primary("review", true, true))
        assertEquals("supplement", VoiceWidgetFlow.primary("review", false, true))
        assertEquals("speak", VoiceWidgetFlow.primary("saved", true, false))
    }
    @Test fun repeatedClicksDuringProcessingNeverStartOrSave() {
        for (phase in VoiceWidgetFlow.busy) {
            assertNull(VoiceWidgetFlow.primary(phase, true, true))
            assertNull(VoiceWidgetFlow.primary(phase, false, false))
        }
    }
    @Test fun interruptedConfirmationCanRetryTheSameDraft() {
        assertEquals("confirm", VoiceWidgetFlow.primary("error", true, true))
        assertEquals("speak", VoiceWidgetFlow.primary("error", false, false))
    }
}
