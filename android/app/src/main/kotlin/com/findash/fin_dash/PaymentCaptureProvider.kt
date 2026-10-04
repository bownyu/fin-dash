package com.findash.fin_dash

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Binder
import android.os.Bundle
import android.os.Process

/** Single owner of capture preferences and inbox, including across app upgrades. */
class PaymentCaptureProvider : ContentProvider() {
    override fun onCreate() = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        check(Binder.getCallingUid() == Process.myUid()) { "Private capture interface" }
        val app = checkNotNull(context).applicationContext
        val prefs = app.getSharedPreferences("payment_capture", Context.MODE_PRIVATE)
        val inbox = NotificationInbox.get(app)
        return when (method) {
            "status" -> synchronized(inbox) {
                Bundle().apply {
                    putBoolean("enabled", prefs.getBoolean("enabled", false))
                    putBoolean("granted", PaymentListenerConnection.granted(app))
                    putBoolean("connected", PaymentNotificationListener.connected)
                    putInt("queued", inbox.count())
                    putLong("lastReceived", prefs.getLong("lastReceived", 0))
                    putInt("overflow", prefs.getInt("overflow", 0))
                    putBoolean("storageError", prefs.getBoolean("storageError", false))
                }
            }
            "setEnabled" -> {
                val enabled = extras?.getBoolean("enabled") == true
                synchronized(inbox) {
                    check(prefs.edit().putBoolean("enabled", enabled).commit()) { "Cannot save capture setting" }
                }
                if (enabled) PaymentListenerConnection.reconnect(app, manual = true) else PaymentListenerConnection.pause()
                Bundle.EMPTY
            }
            "reconnect" -> {
                PaymentListenerConnection.reconnect(app, manual = extras?.getBoolean("manual") == true)
                Bundle.EMPTY
            }
            "peek" -> Bundle().apply {
                putParcelableArrayList("events", ArrayList(inbox.peek().map { it.toCaptureBundle() }))
            }
            "ack" -> {
                val ids = extras?.getStringArrayList("ids") ?: throw IllegalArgumentException("Missing event IDs")
                require(ids.size <= 100 && ids.all { it.length == 64 && it.all { c -> c in '0'..'9' || c in 'a'..'f' } })
                inbox.acknowledge(ids)
                Bundle.EMPTY
            }
            "clear" -> synchronized(inbox) {
                inbox.clear()
                check(prefs.edit().putInt("overflow", 0).putBoolean("storageError", false).commit())
                Bundle.EMPTY
            }
            else -> throw IllegalArgumentException("Unknown capture method")
        }
    }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
}

private fun Map<String, Any?>.toCaptureBundle() = Bundle().apply {
    for ((key, value) in this@toCaptureBundle) {
        when (value) {
            null -> putString(key, null)
            is String -> putString(key, value)
            is Int -> putInt(key, value)
            is Long -> putLong(key, value)
            is Boolean -> putBoolean(key, value)
            else -> throw IllegalArgumentException("Invalid capture field")
        }
    }
}
