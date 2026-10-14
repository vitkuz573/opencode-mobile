package dev.vitkuz573.opencodemobile.tunnel

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Carries a tunnel's TLS between the app and [TlsTerminator].
 *
 * Bytes travel as byte arrays rather than as text: a visitor's TLS record is not
 * text, and anything that reinterprets one on the way through is a bug waiting
 * for the first non-ASCII byte in a certificate.
 *
 * Every reply goes out on the platform thread, because a method call may not be
 * made from anywhere else, and the terminator works on its own thread.
 */
class TunnelTlsChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, NAME)
    private val main = Handler(Looper.getMainLooper())
    private var terminator: TlsTerminator? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepare" -> {
                val chain = call.argument<String>("certificateChain")
                val key = call.argument<String>("privateKey")
                if (chain == null || key == null) {
                    result.error("bad_arguments", "a certificate and a key are required", null)
                    return
                }
                try {
                    ensureTerminator().prepare(chain, key)
                    result.success(null)
                } catch (failure: Throwable) {
                    result.error("prepare_failed", failure.message, null)
                }
            }

            "start" -> dispatch(call, result) { id, _ -> requireTerminator().start(id) }

            "fromVisitor" -> dispatch(call, result) { id, bytes ->
                requireTerminator().fromVisitor(id, bytes)
            }

            "fromApp" -> dispatch(call, result) { id, bytes ->
                requireTerminator().fromApp(id, bytes)
            }

            "close" -> dispatch(call, result) { id, _ -> requireTerminator().close(id) }

            "shutDown" -> {
                terminator?.shutDown()
                terminator = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private inline fun dispatch(
        call: MethodCall,
        result: MethodChannel.Result,
        block: (Long, ByteArray) -> Unit,
    ) {
        val id = call.argument<Number>("connection")?.toLong()
        val bytes = call.argument<ByteArray>("bytes") ?: ByteArray(0)
        if (id == null) {
            result.error("bad_arguments", "a connection is required", null)
            return
        }
        try {
            block(id, bytes)
            result.success(null)
        } catch (failure: Throwable) {
            result.error("call_failed", failure.message, null)
        }
    }

    private fun requireTerminator(): TlsTerminator =
        terminator ?: throw IllegalStateException("the TLS layer was never prepared")

    private fun ensureTerminator(): TlsTerminator {
        val existing = terminator
        if (existing != null) return existing
        val created = TlsTerminator(
            object : TlsSink {
                override fun toVisitor(connection: Long, bytes: ByteArray) =
                    send("toVisitor", connection, bytes)

                override fun toApp(connection: Long, bytes: ByteArray) =
                    send("toApp", connection, bytes)

                override fun ready(connection: Long) = send("ready", connection)

                override fun closed(connection: Long) = send("closed", connection)

                override fun failed(connection: Long, reason: String) =
                    send("failed", connection, null, reason)
            },
        )
        terminator = created
        return created
    }

    private fun send(
        method: String,
        connection: Long,
        bytes: ByteArray? = null,
        reason: String? = null,
    ) {
        val arguments = mutableMapOf<String, Any>("connection" to connection)
        if (bytes != null) arguments["bytes"] = bytes
        if (reason != null) arguments["reason"] = reason
        main.post { channel.invokeMethod(method, arguments) }
    }

    fun dispose() {
        terminator?.shutDown()
        terminator = null
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val NAME = "dev.vitkuz573.opencodemobile/tunnel_tls"
    }
}