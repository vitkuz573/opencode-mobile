package dev.vitkuz573.opencodemobile.tunnel

import android.util.Base64
import java.io.ByteArrayInputStream
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLEngineResult

/** What a session tells the app as it works. */
interface TlsSink {
    /** Encrypted, on its way back to the visitor. */
    fun toVisitor(connection: Long, bytes: ByteArray)

    /** Decrypted, on its way to the server running on this phone. */
    fun toApp(connection: Long, bytes: ByteArray)

    /** The handshake is done and application data may flow. */
    fun ready(connection: Long)

    /** Nothing more will be said about this connection. */
    fun closed(connection: Long)

    /** The connection could not be served, and here is why. */
    fun failed(connection: Long, reason: String)
}

/**
 * Serves many visitors' TLS at once, one [SSLEngine] each.
 *
 * This lives in Kotlin rather than Dart for one reason. `dart:io`'s
 * `SecureServerSocket` hands over its socket only once the handshake is
 * complete, which makes it useless here: a visitor has to be told the server's
 * half of the handshake *during* that handshake or it never answers, and the
 * handshake never completes. `SSLEngine` is a state machine that emits each
 * flight as it is produced, which is exactly what a byte relay needs.
 *
 * Everything runs on one thread. The engines never block - each call either
 * makes progress or asks for more bytes - so a single thread is enough, and it
 * keeps the order a visitor sees identical to the order it sent.
 */
class TlsTerminator(private val sink: TlsSink) {

    private val executor: ExecutorService =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "tunnel-tls").apply { isDaemon = true }
        }

    private val sessions = ConcurrentHashMap<Long, Session>()

    @Volatile
    private var context: SSLContext? = null

    /** Loads the tunnel's certificate once, rather than per visitor. */
    fun prepare(certificateChainPem: String, privateKeyPem: String) {
        val certificates = parseCertificates(certificateChainPem)
        val key = parsePrivateKey(privateKeyPem)
        // A KeyStore rather than a hand-written KeyManager: the platform's own
        // key managers already know how to match a key to a certificate chain,
        // and an in-memory one keeps the tunnel's key off the disk it was never
        // meant to be readable from.
        val store = KeyStore.getInstance(KeyStore.getDefaultType()).apply {
            load(null, null)
            setKeyEntry(ALIAS, key, PASSPHRASE, certificates.toTypedArray())
        }
        val managers = KeyManagerFactory
            .getInstance(KeyManagerFactory.getDefaultAlgorithm())
            .apply { init(store, PASSPHRASE) }
            .keyManagers
        context = SSLContext.getInstance("TLS").apply { init(managers, null, null) }
    }

    fun start(connection: Long) = onThread {
        val ready = context
            ?: throw IllegalStateException("the terminator was never given a certificate")
        sessions[connection] = Session(connection, newEngine(), sink)
    }

    /** Every engine is the server's side: the visitor is the one dialling. */
    private fun newEngine(): SSLEngine =
        context!!.createSSLEngine().apply {
            useClientMode = false
            needClientAuth = false
        }

    fun fromVisitor(connection: Long, bytes: ByteArray) = onThread {
        sessions[connection]?.consumeVisitor(bytes)
    }

    fun fromApp(connection: Long, bytes: ByteArray) = onThread {
        sessions[connection]?.consumeApp(bytes)
    }

    fun close(connection: Long) = onThread {
        sessions.remove(connection)?.shutdown()
    }

    /** Ends every session and stops the thread. */
    fun shutDown() {
        sessions.keys.toList().forEach { id -> sessions.remove(id)?.shutdown() }
        executor.shutdownNow()
    }

    private fun onThread(block: () -> Unit) {
        executor.execute {
            try {
                block()
            } catch (failure: Throwable) {
                // A terminator that died quietly would leave the tunnel
                // answering for ever, so a failure has to reach the app.
                sink.failed(-1, failure.message ?: failure.toString())
            }
        }
    }

    /**
     * One visitor's TLS, driven by hand.
     *
     * [pending] holds the visitor's bytes that have arrived but not yet been
     * consumed by [SSLEngine.unwrap], which needs a whole TLS record and asks
     * for more rather than taking what it has.
     */
    private inner class Session(
        private val id: Long,
        private val engine: SSLEngine,
        private val sink: TlsSink,
    ) {
        private val empty = ByteBuffer.allocate(0)
        private var pending = ByteArray(INITIAL)
        private var pendingSize = 0
        private var handshakeDone = false
        private var finished = false

        /** Application bytes that arrived before the handshake let them out. */
        private val waiting = ArrayDeque<ByteArray>()

        fun consumeVisitor(bytes: ByteArray) {
            if (finished) return
            try {
                append(bytes)
                unwrap()
                emitHandshakeFlight()
                // The flight may have finished the handshake, in which case
                // whatever else arrived with it is application data.
                unwrap()
            } catch (failure: Throwable) {
                fail(failure)
            }
        }

        fun consumeApp(bytes: ByteArray) {
            if (finished) return
            if (!handshakeDone) {
                // Nothing can be encrypted before the handshake finishes, and
                // the app cannot send before it is told the handshake finished,
                // so this is unreachable rather than a case to handle. Holding
                // the bytes is the honest reading of it.
                waiting.addLast(bytes)
                return
            }
            try {
                wrap(bytes)
            } catch (failure: Throwable) {
                fail(failure)
            }
        }

        fun shutdown() {
            if (finished) return
            finished = true
            runCatching { engine.closeOutbound() }
            sink.closed(id)
        }

        private fun fail(failure: Throwable) {
            if (finished) return
            finished = true
            sink.failed(id, failure.message ?: failure.toString())
        }

        /**
         * Whether the engine considers the handshake over and the bytes it
         * produced application data.
         *
         * A TLS 1.3 server is not finished when it sends its own last flight -
         * it is finished when the visitor's Finished arrives - which is why
         * `NOT_HANDSHAKING` on its own is not the answer here.
         */
        private fun pastHandshake(result: SSLEngineResult): Boolean =
            result.handshakeStatus == SSLEngineResult.HandshakeStatus.FINISHED ||
                result.handshakeStatus == SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING

        private fun append(chunk: ByteArray) {
            if (chunk.isEmpty()) return
            if (pendingSize + chunk.size > pending.size) {
                var size = pending.size
                while (size < pendingSize + chunk.size) size *= 2
                pending = pending.copyOf(size)
            }
            System.arraycopy(chunk, 0, pending, pendingSize, chunk.size)
            pendingSize += chunk.size
        }

        private fun consume(count: Int) {
            System.arraycopy(pending, count, pending, 0, pendingSize - count)
            pendingSize -= count
        }

        /** Feeds the engine whatever it is ready to take, and reports what came out. */
        private fun unwrap() {
            while (!finished && pendingSize > 0) {
                val source = ByteBuffer.wrap(pending, 0, pendingSize)
                val decrypted = ByteBuffer.allocate(INITIAL)
                val result = engine.unwrap(source, decrypted)
                val taken = source.position()
                if (taken > 0) consume(taken)

                if (result.status == SSLEngineResult.Status.BUFFER_OVERFLOW) {
                    // The bytes were fine; the output buffer was too small,
                    // which is worth another try with a bigger one.
                    continue
                }
                if (result.bytesProduced() > 0) {
                    decrypted.flip()
                    val clear = ByteArray(decrypted.remaining())
                    decrypted.get(clear)
                    // The engine says so itself: a handshake record and a
                    // request look alike until it does.
                    if (pastHandshake(result) || handshakeDone) sink.toApp(id, clear)
                }
                when (result.status) {
                    SSLEngineResult.Status.OK ->
                        if (pastHandshake(result)) finishHandshake()
                    SSLEngineResult.Status.BUFFER_UNDERFLOW -> return
                    SSLEngineResult.Status.CLOSED -> {
                        shutdown()
                        return
                    }
                    SSLEngineResult.Status.BUFFER_OVERFLOW -> continue
                }
                if (taken == 0 && result.bytesProduced() == 0) return
            }
        }

        /**
         * Sends whatever the engine wants to say.
         *
         * A TLS 1.3 server's whole flight - ServerHello, certificate, finished -
         * is produced as soon as it has the ClientHello, and the visitor cannot
         * answer until it has been sent. This is the call that sends it, and it
         * is the reason this class exists.
         */
        private fun emitHandshakeFlight() {
            var guard = 0
            while (!finished && !handshakeDone && guard++ < MAX_FLIGHTS) {
                val encrypted = ByteBuffer.allocate(INITIAL)
                engine.wrap(empty, encrypted)
                val produced = encrypted.position()
                if (produced == 0) break
                encrypted.flip()
                val bytes = ByteArray(encrypted.remaining())
                encrypted.get(bytes)
                sink.toVisitor(id, bytes)
                if (engine.handshakeStatus == SSLEngineResult.HandshakeStatus.NOT_HANDSHAKING) {
                    finishHandshake()
                }
            }
        }

        private fun finishHandshake() {
            if (handshakeDone) return
            handshakeDone = true
            sink.ready(id)
            while (waiting.isNotEmpty() && !finished) {
                wrap(waiting.removeFirst())
            }
        }

        private fun wrap(clear: ByteArray) {
            val encrypted = ByteBuffer.allocate(clear.size + OVERHEAD)
            engine.wrap(ByteBuffer.wrap(clear), encrypted)
            encrypted.flip()
            val bytes = ByteArray(encrypted.remaining())
            encrypted.get(bytes)
            if (bytes.isNotEmpty()) sink.toVisitor(id, bytes)
        }
    }

    private companion object {
        const val ALIAS = "opencodemobile-tunnel"

        /**
         * The in-memory keystore's own protection. The key was never written to
         * disk, so this guards nothing on its own and only satisfies the API.
         */
        val PASSPHRASE = charArrayOf('t', 'u', 'n', 'n', 'e', 'l')
        const val INITIAL = 16 * 1024
        const val OVERHEAD = 1024

        /**
         * Bounds a handshake that keeps producing flights without finishing.
         * A real one is under ten; this is here so a hostile visitor cannot keep
         * the single terminator thread busy for ever.
         */
        const val MAX_FLIGHTS = 64

        fun parseCertificates(pem: String): List<X509Certificate> {
            val factory = CertificateFactory.getInstance("X.509")
            return pemBlocks(pem).map { block ->
                factory.generateCertificate(ByteArrayInputStream(block)) as X509Certificate
            }
        }

        fun parsePrivateKey(pem: String): PrivateKey {
            val spec = PKCS8EncodedKeySpec(pemBlocks(pem).first())
            // The tunnel mints P-256, but the algorithm is read off the key
            // rather than assumed: a certificate cannot be served with a key the
            // platform cannot load, and failing here says so plainly.
            val failures = mutableListOf<Throwable>()
            for (algorithm in listOf("EC", "RSA")) {
                try {
                    return KeyFactory.getInstance(algorithm).generatePrivate(spec)
                } catch (failure: Throwable) {
                    failures += failure
                }
            }
            throw IllegalArgumentException(
                "the tunnel key is neither EC nor RSA",
                failures.firstOrNull(),
            )
        }

        /** Every base64 body between PEM headers, decoded. */
        fun pemBlocks(pem: String): List<ByteArray> =
            pem.split("-----")
                .asSequence()
                .filter { it.isNotBlank() && !it.startsWith("BEGIN") && !it.startsWith("END") }
                .map { Base64.decode(it.replace(Regex("\\s"), ""), Base64.DEFAULT) }
                .toList()
    }
}