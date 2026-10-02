package com.findash.fin_dash

/** Processing must never start another recording or save. */
object VoiceWidgetFlow {
    val busy = setOf("starting", "recognizing", "parsing", "saving")
    fun primary(phase: String, canConfirm: Boolean, hasDraft: Boolean): String? = when {
        phase in busy -> null
        phase == "listening" -> "stop"
        hasDraft && canConfirm -> "confirm"
        hasDraft -> "supplement"
        else -> "speak"
    }
}
