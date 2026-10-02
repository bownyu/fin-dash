package com.findash.fin_dash

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import java.security.MessageDigest
import java.util.concurrent.Executors
import org.json.JSONObject

class PaymentNotificationListener : NotificationListenerService() {
    companion object { @Volatile var connected = false }
    private val worker = Executors.newSingleThreadExecutor()
    private val prefs get() = getSharedPreferences("payment_capture", MODE_PRIVATE)

    override fun onListenerConnected() { connected = true }
    override fun onListenerDisconnected() { connected = false }
    override fun onDestroy() { connected = false; worker.shutdown(); super.onDestroy() }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (!prefs.getBoolean("enabled", false) || sbn.packageName !in PaymentRules.packages) return
        val notification = sbn.notification
        if (notification.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val extras = notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.take(200) ?: ""
        val text = listOfNotNull(
            extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString(),
            extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)?.joinToString("\n")
        ).distinct().joinToString("\n").take(4096)
        val match = PaymentRules.parse(sbn.packageName, title, text) ?: return
        val key = sbn.key
        val postedAt = sbn.postTime
        val identity = JSONObject().put("package", sbn.packageName).put("key", key)
            .put("postedAt", postedAt).put("title", title).put("text", text).toString()
        val id = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val payload = JSONObject().apply {
            put("eventId", id); put("sourcePackage", sbn.packageName); put("notificationKey", key)
            put("postedAt", postedAt); put("title", title); put("text", text)
            put("amountCents", match.amountCents ?: JSONObject.NULL); put("kind", match.kind)
            put("merchant", match.merchant); put("reviewReason", match.reviewReason)
            put("ruleVersion", PaymentRules.VERSION)
        }
        worker.execute {
            try {
                val inbox = NotificationInbox.get(this)
                synchronized(inbox) {
                    // Share the toggle's lock: no callback may write after disable completes.
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
    }
}
