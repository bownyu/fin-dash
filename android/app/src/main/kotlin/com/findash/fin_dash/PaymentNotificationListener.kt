package com.findash.fin_dash

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.security.MessageDigest
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import org.json.JSONObject

class PaymentNotificationListener : NotificationListenerService() {
    companion object {
        @Volatile var connected = false
            private set
        private var listener: PaymentNotificationListener? = null

        fun pause() {
            if (connected) {
                try { listener?.requestUnbind() } catch (_: Exception) { }
            }
            connected = false
        }
    }
    // A bounded queue; the worker thread exits after 10 idle seconds.
    private val worker = ThreadPoolExecutor(1, 1, 10, TimeUnit.SECONDS, ArrayBlockingQueue(64),
        { work -> Thread(work, "payment-capture-worker") }).apply {
        allowCoreThreadTimeOut(true)
    }
    private val prefs get() = getSharedPreferences("payment_capture", MODE_PRIVATE)

    override fun onListenerConnected() {
        listener = this
        connected = true
        PaymentListenerConnection.connected()
        if (!prefs.getBoolean("enabled", false)) PaymentListenerConnection.pause()
    }
    override fun onListenerDisconnected() {
        connected = false
        PaymentListenerConnection.reconnect(applicationContext)
    }
    override fun onDestroy() {
        if (listener === this) { listener = null; connected = false }
        worker.shutdown()
        PaymentListenerConnection.reconnect(applicationContext)
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName !in PaymentRules.packages || !prefs.getBoolean("enabled", false)) return
        val notification = sbn.notification
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.take(200) ?: ""
        if (!PaymentRules.acceptsTitle(sbn.packageName, title)) return
        val text = listOfNotNull(
            extras.getCharSequence(Notification.EXTRA_TEXT)?.take(4096)?.toString(),
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.take(4096)?.toString(),
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.let { lines ->
                buildString {
                    for (line in lines) {
                        if (length >= 4096) break
                        if (isNotEmpty()) append('\n')
                        append(line.take((4096 - length).coerceAtLeast(0)))
                    }
                }
            }
        ).distinct().joinToString("\n").take(4096)
        val packageName = sbn.packageName
        val key = sbn.key
        val postedAt = sbn.postTime
        try {
            worker.execute {
                try {
                    if (!prefs.getBoolean("enabled", false)) return@execute
                    val match = PaymentRules.parse(packageName, title, text) ?: return@execute
                    val identity = JSONObject().put("package", packageName).put("key", key)
                        .put("postedAt", postedAt).put("title", title).put("text", text).toString()
                    val id = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
                        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
                    val payload = JSONObject().apply {
                        put("eventId", id); put("sourcePackage", packageName); put("notificationKey", key)
                        put("postedAt", postedAt); put("title", title); put("text", text)
                        put("amountCents", match.amountCents ?: JSONObject.NULL); put("kind", match.kind)
                        put("merchant", match.merchant); put("reviewReason", match.reviewReason)
                        put("ruleVersion", PaymentRules.VERSION)
                    }
                    val inbox = NotificationInbox.get(this)
                    synchronized(inbox) {
                        // Toggle and capture share one process and lock. Disable commits first.
                        if (!prefs.getBoolean("enabled", false)) return@execute
                        val stored = inbox.put(id, payload, postedAt)
                        prefs.edit().putLong("lastReceived", postedAt)
                            .putInt("overflow", prefs.getInt("overflow", 0) + if (stored) 0 else 1)
                            .putBoolean("storageError", false).apply()
                    }
                } catch (_: Exception) {
                    // Do not log notification bodies or financial data.
                    prefs.edit().putBoolean("storageError", true).apply()
                }
            }
        } catch (_: RejectedExecutionException) {
            synchronized(NotificationInbox.get(this)) {
                prefs.edit().putInt("overflow", prefs.getInt("overflow", 0) + 1).apply()
            }
        }
    }
}
