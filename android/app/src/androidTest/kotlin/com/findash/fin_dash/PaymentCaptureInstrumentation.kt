package com.findash.fin_dash

import android.app.Activity
import android.app.ActivityManager
import android.app.Instrumentation
import android.content.ContentValues
import android.content.Context
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import org.json.JSONObject

/** Framework-only device checks; adds no runtime or test-library dependency. */
class PaymentCaptureInstrumentation : Instrumentation() {
    private var mode = "ipc"

    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        mode = arguments?.getString("mode") ?: "ipc"
        start()
    }

    override fun onStart() {
        val result = Bundle()
        try {
            // This test deliberately seeds synthetic data, only in the separate test app.
            check(targetContext.packageName == "com.findash.fin_dash.validation") { "Use the background validation build" }
            when (mode) {
                "seed" -> seedLegacyInbox()
                "ipc" -> checkPrivateIpc()
                "enable" -> enableListener()
                "capture" -> checkSyntheticCapture()
                else -> error("Unknown validation mode")
            }
            result.putString("result", "$mode passed")
            finish(Activity.RESULT_OK, result)
        } catch (failure: Throwable) {
            result.putString("failure", failure.toString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun seedLegacyInbox() {
        check(targetContext.getSharedPreferences("payment_capture", Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", true).putLong("lastReceived", 42).putInt("overflow", 7).commit())
        val db = NotificationInbox.get(targetContext).writableDatabase
        db.beginTransaction()
        try {
            db.delete("events", null, null)
            repeat(300) { index ->
                val id = index.toString(16).padStart(64, '0')
                val payload = JSONObject().apply {
                    put("eventId", id); put("sourcePackage", "com.tencent.mm")
                    put("notificationKey", "fixture-$index"); put("postedAt", 1_700_000_000_000L + index)
                    put("title", "微信支付"); put("text", "测".repeat(4096))
                    put("amountCents", if (index == 0) JSONObject.NULL else 150L)
                    put("kind", "expense"); put("merchant", "合成测试")
                    put("reviewReason", "测试通知"); put("ruleVersion", 2)
                }
                db.insertOrThrow("events", null, ContentValues().apply {
                    put("id", id); put("payload", payload.toString()); put("posted_at", 1_700_000_000_000L + index)
                })
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }

    @Suppress("UNCHECKED_CAST")
    private fun checkPrivateIpc() {
        val client = PaymentCaptureClient(targetContext)
        val initial = client.call("status") as Map<String, Any?>
        check(initial["enabled"] == true && initial["queued"] == 300)
        check(initial["lastReceived"] == 42L && initial["overflow"] == 7)
        client.call("setEnabled", mapOf("enabled" to false))
        check((client.call("status") as Map<*, *>)["enabled"] == false)
        val remote = targetContext.getSystemService(ActivityManager::class.java).runningAppProcesses
            .first { it.processName == "${targetContext.packageName}:payment_capture" }
        check(remote.pid != Process.myPid()) { "Capture must run in a different process" }
        val seen = mutableSetOf<String>()
        var pages = 0
        while (true) {
            val page = client.call("peek") as List<Map<String, Any?>>
            if (page.isEmpty()) break
            check(page.size in 1..100)
            check(page.sumOf { (it["text"] as String).length * 2 } <= 128 * 1024)
            page.forEach { record ->
                check(seen.add(record["eventId"] as String)) { "Event replayed after ACK" }
                check(record["sourcePackage"] == "com.tencent.mm")
                check(record["postedAt"] is Long)
                if (record["eventId"] == "0".repeat(64)) check(record["amountCents"] == null)
            }
            client.call("ack", mapOf("ids" to page.map { it["eventId"] }))
            check(++pages <= 100)
        }
        check(seen.size == 300 && pages > 10) { "Large pages must drain without loss" }
        check((client.call("status") as Map<*, *>)["queued"] == 0)
        client.call("clear")
        check((client.call("status") as Map<*, *>)["overflow"] == 0)
    }

    private fun enableListener() {
        val client = PaymentCaptureClient(targetContext)
        client.call("setEnabled", mapOf("enabled" to true))
        val deadline = SystemClock.elapsedRealtime() + 10_000
        while (SystemClock.elapsedRealtime() < deadline) {
            val status = client.call("status") as Map<*, *>
            check(status["granted"] == true) { "Grant listener access on the test emulator first" }
            if (status["connected"] == true) return
            SystemClock.sleep(100)
        }
        error("Listener did not connect")
    }

    private fun checkSyntheticCapture() {
        val client = PaymentCaptureClient(targetContext)
        val page = client.call("peek") as List<*>
        check(page.size == 1)
        val record = page.single() as Map<*, *>
        check(record["sourcePackage"] == "com.tencent.mm" && record["merchant"] == "合成测试")
        check(record["amountCents"] == 150 && record["kind"] == "expense")
        client.call("ack", mapOf("ids" to listOf(record["eventId"])))
        check((client.call("status") as Map<*, *>)["queued"] == 0)
        client.call("setEnabled", mapOf("enabled" to false))
        check((client.call("status") as Map<*, *>)["enabled"] == false)
    }
}
