package com.findash.fin_dash

import android.content.Context
import android.net.Uri
import android.os.Bundle

/** Short IPC calls only while the app is in use; never binds or starts Flutter. */
class PaymentCaptureClient(context: Context) {
    private val app = context.applicationContext
    private val uri = Uri.parse("content://${app.packageName}.payment_capture")

    fun call(method: String, arguments: Map<String, Any?> = emptyMap()): Any? {
        val extras = when (method) {
            "setEnabled" -> Bundle().apply { putBoolean("enabled", arguments["enabled"] == true) }
            "reconnect" -> Bundle().apply { putBoolean("manual", arguments["manual"] == true) }
            "ack" -> Bundle().apply {
                val ids = arguments["ids"] as? List<*> ?: throw IllegalArgumentException("Missing event IDs")
                require(ids.all { it is String })
                putStringArrayList("ids", ArrayList(ids.map { it as String }))
            }
            else -> null
        }
        val reply = checkNotNull(app.contentResolver.call(uri, method, null, extras))
        return when (method) {
            "status" -> reply.captureMap()
            "peek" -> {
                @Suppress("DEPRECATION")
                val events = reply.getParcelableArrayList<Bundle>("events") ?: error("Missing capture page")
                events.map { it.captureMap() }
            }
            else -> null
        }
    }
}

@Suppress("DEPRECATION")
private fun Bundle.captureMap(): Map<String, Any?> = keySet().associateWith { get(it) }
