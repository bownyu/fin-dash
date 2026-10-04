package com.findash.fin_dash

import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService

/** All state belongs to :payment_capture; other processes use the private provider. */
object PaymentListenerConnection {
    private val handler = Handler(Looper.getMainLooper())
    private val policy = PaymentRecoveryPolicy()
    private var pending: Runnable? = null

    fun granted(context: Context): Boolean {
        val component = ComponentName(context, PaymentNotificationListener::class.java)
        val listeners = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners") ?: ""
        return listeners.split(':').any { ComponentName.unflattenFromString(it) == component }
    }

    private fun canListen(context: Context): Boolean =
        context.getSharedPreferences("payment_capture", Context.MODE_PRIVATE).getBoolean("enabled", false) && granted(context)

    private fun onMain(action: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) action() else handler.post { action() }
    }

    private fun cancel() {
        pending?.let { handler.removeCallbacks(it) }
        pending = null
    }

    fun connected() = onMain {
        cancel()
        policy.reset()
    }

    fun pause() = onMain {
        cancel()
        policy.reset()
        PaymentNotificationListener.pause()
    }

    fun reconnect(context: Context, manual: Boolean = false) {
        val app = context.applicationContext
        onMain {
            if (!canListen(app)) {
                cancel()
                return@onMain
            }
            if (PaymentNotificationListener.connected) {
                connected()
                return@onMain
            }
            if (!manual && pending != null) return@onMain
            if (!policy.start(SystemClock.elapsedRealtime(), manual)) return@onMain
            cancel()
            scheduleNext(app)
        }
    }

    private fun scheduleNext(context: Context) {
        val delay = policy.nextDelayMillis() ?: return
        val task = Runnable {
            pending = null
            if (PaymentNotificationListener.connected || !canListen(context)) return@Runnable
            try {
                NotificationListenerService.requestRebind(ComponentName(context, PaymentNotificationListener::class.java))
            } catch (_: Exception) {
                // The next bounded attempt may recover a transient system failure.
            }
            scheduleNext(context)
        }
        pending = task
        handler.postDelayed(task, delay)
    }
}
