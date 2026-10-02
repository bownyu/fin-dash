package com.findash.fin_dash

import java.util.concurrent.atomic.AtomicReference

/** Silence and elapsed time have no transition; completion requires stop or cancel. */
class ManualRecordingSession {
    enum class Phase { IDLE, STARTING, RECORDING, RECOGNIZING, FINISHED, CANCELLED }
    private val phase = AtomicReference(Phase.IDLE)
    val recording get() = phase.get() == Phase.RECORDING
    val cancelled get() = phase.get() == Phase.CANCELLED
    fun start() = phase.compareAndSet(Phase.IDLE, Phase.STARTING)
    fun ready() = phase.compareAndSet(Phase.STARTING, Phase.RECORDING)
    fun stop(): Boolean = phase.compareAndSet(Phase.RECORDING, Phase.RECOGNIZING) ||
        phase.compareAndSet(Phase.STARTING, Phase.RECOGNIZING)
    fun cancel() { phase.set(Phase.CANCELLED) }
    fun finish(): Boolean {
        while (true) {
            val previous = phase.get()
            if (previous == Phase.CANCELLED || previous == Phase.FINISHED) return false
            if (phase.compareAndSet(previous, Phase.FINISHED)) return true
        }
    }
}
