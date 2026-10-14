package dev.vitkuz573.opencodemobile

import dev.vitkuz573.opencodemobile.tunnel.TunnelTlsChannel
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

        // Terminates a tunnel visitor's TLS. Kept for the life of the engine,
        // because a tunnel published from a later session is a different
        // conversation and must not find a half-built terminator.
        tunnelTls = TunnelTlsChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    private var tunnelTls: TunnelTlsChannel? = null

    override fun onDestroy() {
        tunnelTls?.dispose()
        tunnelTls = null
        super.onDestroy()
    }
}