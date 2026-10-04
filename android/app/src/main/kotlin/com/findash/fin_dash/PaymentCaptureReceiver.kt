package com.findash.fin_dash

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** System events only; no alarms, jobs or repeating wakeups. */
class PaymentCaptureReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        try {
            PaymentListenerConnection.reconnect(context)
        } catch (_: Exception) {
            // Missing permission or an OEM restriction must not crash startup.
        }
    }
}
