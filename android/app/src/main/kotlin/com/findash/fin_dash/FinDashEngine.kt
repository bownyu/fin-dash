package com.findash.fin_dash

import android.content.Context
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One runtime owns the ledger even when the desktop widget is used first. */
object FinDashEngine {
    private var engine: FlutterEngine? = null
    private var ready = false
    private var showRequested = false
    private var channel: MethodChannel? = null
    private val waiting = mutableListOf<(FlutterEngine) -> Unit>()

    fun get(context: Context, showApp: Boolean = false): FlutterEngine {
        showRequested = showRequested || showApp
        engine?.let {
            if (ready && showApp) channel?.invokeMethod("showApp", null)
            return it
        }
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context.applicationContext)
        loader.ensureInitializationComplete(context.applicationContext, null)
        val created = FlutterEngine(context.applicationContext)
        engine = created
        channel = MethodChannel(created.dartExecutor.binaryMessenger, "findash/voice_widget").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                if (call.method == "ready") {
                    ready = true
                    result.success(null)
                    if (showRequested) bridge.invokeMethod("showApp", null)
                    val callbacks = waiting.toList()
                    waiting.clear()
                    callbacks.forEach { it(created) }
                } else result.notImplemented()
            }
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "main"), listOf(if (showApp) "app" else "widget"))
        return created
    }

    fun whenReady(context: Context, callback: (FlutterEngine) -> Unit) {
        val current = get(context)
        if (ready) callback(current) else waiting.add(callback)
    }
}
