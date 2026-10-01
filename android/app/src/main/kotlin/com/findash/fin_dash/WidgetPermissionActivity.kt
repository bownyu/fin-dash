package com.findash.fin_dash

import android.Manifest
import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle

/** Only hosts the Android permission prompt; never attaches the app UI. */
class WidgetPermissionActivity : Activity() {
    private val widgetId get() = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT < 23 || checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) start()
        else requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
    }
    private fun start() { WidgetVoiceService.launch(this, widgetId, intent.getStringExtra("operation") ?: "speak"); finish() }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) start()
        else { VoiceWidgetState.show(this, widgetId, "请允许麦克风权限后再试"); finish() }
    }
}
