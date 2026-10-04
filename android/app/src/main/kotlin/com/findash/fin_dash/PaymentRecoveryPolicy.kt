package com.findash.fin_dash

/** A short recovery burst after an event, never a recurring keep-alive timer. */
class PaymentRecoveryPolicy {
    private var startedAt: Long? = null
    private var attempt = 0
    private val delays = longArrayOf(0, 10_000, 30_000)

    fun start(now: Long, manual: Boolean = false): Boolean {
        if (!manual && startedAt?.let { now - it < 30_000 } == true) return false
        startedAt = now
        attempt = 0
        return true
    }

    fun nextDelayMillis(): Long? = delays.getOrNull(attempt)?.also { attempt++ }

    fun reset() {
        startedAt = null
        attempt = 0
    }
}
