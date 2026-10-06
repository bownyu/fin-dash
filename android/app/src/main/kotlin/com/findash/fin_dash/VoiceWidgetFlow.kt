package com.findash.fin_dash

/** Processing must never start another recording or save. */
object VoiceWidgetFlow {
    val busy = setOf("starting", "recognizing", "parsing", "saving")
    /** [reviewing] is an unsaved draft; [openApp] marks drafts only the app can finish. */
    fun primary(phase: String, canConfirm: Boolean, reviewing: Boolean, openApp: Boolean = false): String? = when {
        phase in busy -> null
        phase == "listening" -> "stop"
        reviewing && openApp -> "open"
        reviewing && canConfirm -> "confirm"
        reviewing -> "supplement"
        else -> "speak"
    }
}
