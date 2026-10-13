package dev.vitkuz573.opencodemobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Holds the phone-hosted OpenCode server alive in the background.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.vitkuz573.opencodemobile/keepalive",
        ).setMethodCallHandler(KeepAliveChannel(applicationContext))
    }
}