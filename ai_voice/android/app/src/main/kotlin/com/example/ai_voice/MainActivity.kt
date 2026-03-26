package com.example.ai_voice

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val CHANNEL = "voxshield/overlay_messenger"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            // This is the bridge back to the app from the overlay engine
            // If the overlay sends a broadcast, we receive it here and tell the app engine
            if (call.method == "toggle_record" || call.method == "report_scam") {
                // Since this engine is already running the main app, we just return success
                // The actual handler is in CallService.dart using the same channel
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }
}
