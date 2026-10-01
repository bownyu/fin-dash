package com.findash.fin_dash

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var voiceBridge: VoiceBridge? = null
    override fun provideFlutterEngine(context: Context): FlutterEngine = FinDashEngine.get(context, showApp = true)
    override fun shouldDestroyEngineWithHost(): Boolean = false
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        voiceBridge = VoiceBridge(this, flutterEngine.dartExecutor.binaryMessenger)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        voiceBridge?.onPermission(requestCode, grantResults)
    }
    override fun onDestroy() { voiceBridge?.destroy(); super.onDestroy() }
}
