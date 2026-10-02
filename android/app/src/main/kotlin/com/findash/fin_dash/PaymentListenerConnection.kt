package com.findash.fin_dash

import android.content.ComponentName
import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService

/** Permission survives some installs independently of the system's service binding. */
object PaymentListenerConnection {
    private var lastRequest: Long? = null

    fun granted(context: Context): Boolean {
        val component = ComponentName(context, PaymentNotificationListener::class.java)
        val listeners = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: ""
        return listeners.split(':').any { ComponentName.unflattenFromString(it) == component }
    }

    @Synchronized
    fun reconnect(context: Context, manual: Boolean = false): Boolean {
        if (!context.getSharedPreferences("payment_capture", Context.MODE_PRIVATE).getBoolean("enabled", false) ||
            !granted(context) || PaymentNotificationListener.connected) return false
        val now = SystemClock.elapsedRealtime()
        if (!manual && lastRequest?.let { now - it < 30_000 } == true) return false
        NotificationListenerService.requestRebind(ComponentName(context, PaymentNotificationListener::class.java))
        lastRequest = now
        return true
    }
}
