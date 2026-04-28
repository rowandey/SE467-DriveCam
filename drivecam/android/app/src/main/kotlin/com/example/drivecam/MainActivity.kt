package com.example.drivecam

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Register the HLS export MethodChannel during Flutter engine setup so
    // Dart can remux segments into a single MP4 for gallery export without
    // pulling in ffmpeg.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, HlsExportHandler.CHANNEL)
            .setMethodCallHandler { call, result -> HlsExportHandler.handle(call, result) }
    }
}
