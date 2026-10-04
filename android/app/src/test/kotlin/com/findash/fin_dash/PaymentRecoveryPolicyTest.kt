package com.findash.fin_dash

import org.junit.Assert.*
import org.junit.Test

class PaymentRecoveryPolicyTest {
    @Test fun recoveryStopsAfterThreeAttempts() {
        val policy = PaymentRecoveryPolicy()
        assertTrue(policy.start(100))
        assertEquals(0L, policy.nextDelayMillis())
        assertEquals(10_000L, policy.nextDelayMillis())
        assertEquals(30_000L, policy.nextDelayMillis())
        repeat(20) { assertNull(policy.nextDelayMillis()) }
    }

    @Test fun duplicateLifecycleEventsCannotStartFrequentBursts() {
        val policy = PaymentRecoveryPolicy()
        assertTrue(policy.start(100))
        assertFalse(policy.start(101))
        assertFalse(policy.start(30_099))
        assertTrue(policy.start(30_100))
    }

    @Test fun userCanRetryImmediatelyAndConnectionResetsTheBudget() {
        val policy = PaymentRecoveryPolicy()
        assertTrue(policy.start(100))
        repeat(3) { policy.nextDelayMillis() }
        assertTrue(policy.start(101, manual = true))
        assertEquals(0L, policy.nextDelayMillis())
        policy.reset()
        assertTrue(policy.start(102))
        assertEquals(0L, policy.nextDelayMillis())
    }
}
