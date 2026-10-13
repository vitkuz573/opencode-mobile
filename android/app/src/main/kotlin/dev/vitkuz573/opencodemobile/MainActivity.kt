package dev.vitkuz573.opencodemobile

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// A fragment activity rather than a plain one: the biometric prompt used by
// the app lock is a Fragment, and it has nowhere to attach otherwise.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Holds the phone-hosted OpenCode server alive in the background.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "dev.vitkuz573.opencodemobile/keepalive",
        ).setMethodCallHandler(KeepAliveChannel(applicationContext))
    }
}