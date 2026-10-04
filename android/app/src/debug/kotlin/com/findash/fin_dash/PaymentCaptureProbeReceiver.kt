package com.findash.fin_dash

import android.app.Activity
import android.app.Notification
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Process
import android.os.SystemClock
import android.os.UserHandle
import android.service.notification.StatusBarNotification

/** Emulator-only synthetic callback probe. Never packaged in release APKs. */
class PaymentCaptureProbeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        check(context.packageName == "com.findash.fin_dash.validation")
        if (intent.getStringExtra("mode") != "inject") {
            resultCode = Activity.RESULT_OK
            resultData = "connected=${PaymentNotificationListener.connected},queued=${NotificationInbox.get(context).count()},pid=${Process.myPid()}"
            return
        }
        // Use the actual bound service, so this cannot silently start a replacement listener.
        val field = PaymentNotificationListener::class.java.getDeclaredField("listener").apply { isAccessible = true }
        val listener = field.get(null) as? PaymentNotificationListener
        if (listener == null || !PaymentNotificationListener.connected) {
            resultCode = Activity.RESULT_CANCELED
            resultData = "Listener is not bound"
            return
        }
        val inbox = NotificationInbox.get(context)
        val before = inbox.count()
        val postedAt = System.currentTimeMillis()
        val notification = Notification.Builder(context, "capture-validation")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("微信支付")
            .setContentText("支付￥1.50（合成测试）")
            .build()
        listener.onNotificationPosted(StatusBarNotification("com.tencent.mm", "com.tencent.mm", 1,
            "synthetic-$postedAt", Process.myUid(), Process.myPid(), 0, notification,
            UserHandle.getUserHandleForUid(Process.myUid()), postedAt))
        val pending = goAsync()
        Thread {
            try {
                val deadline = SystemClock.elapsedRealtime() + 3000
                while (inbox.count() == before && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(25)
                check(inbox.count() == before + 1) { "Synthetic payment was not stored" }
                pending.resultCode = Activity.RESULT_OK
                pending.resultData = "synthetic payment saved,pid=${Process.myPid()}"
            } catch (failure: Throwable) {
                pending.resultCode = Activity.RESULT_CANCELED
                pending.resultData = failure.toString()
            } finally { pending.finish() }
        }.start()
    }
}
