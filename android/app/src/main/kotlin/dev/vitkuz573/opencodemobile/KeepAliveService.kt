package dev.vitkuz573.opencodemobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps the app process alive while the phone-hosted OpenCode server runs.
 *
 * The server is a child process of the app. Android reclaims backgrounded apps
 * after a few minutes, and it takes that child with it, so a server that was
 * working would silently stop working when the screen went off. A foreground
 * service is the only way to hold the process — and it tells the user plainly
 * that something of theirs is running, which a silent keep-alive must not do.
 */
class KeepAliveService : android.app.Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val address = intent?.getStringExtra(EXTRA_ADDRESS).orEmpty()
        startForeground(NOTIFICATION_ID, build(address))
        // Not sticky: the Dart side owns the lifetime and restarts the server
        // deliberately. Being restarted without it would run a server nobody
        // is looking after.
        return START_NOT_STICKY
    }

    private fun build(address: String): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val body = if (address.isEmpty()) {
            "OpenCode is running on this phone"
        } else {
            "Serving $address"
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("OpenCode on this phone")
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(open)
            .build()
    }

    companion object {
        const val CHANNEL_ID = "opencode.local_server"
        const val NOTIFICATION_ID = 0x0C0E
        const val EXTRA_ADDRESS = "address"

        fun start(context: Context, address: String) {
            ensureChannel(context)
            val intent = Intent(context, KeepAliveService::class.java)
                .putExtra(EXTRA_ADDRESS, address)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, KeepAliveService::class.java))
        }

        private fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager =
                context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "OpenCode on this phone",
                // Low: nothing here is urgent, and a notification that buzzes
                // for a server the user deliberately started is a nuisance.
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while this phone is serving OpenCode sessions"
                setShowBadge(false)
            }
            manager.createNotificationChannel(channel)
        }
    }
}

/**
 * Bridges the Dart side to the platform.
 *
 * `nativeLibraryDir` is the reason this channel exists at all: it is the one
 * directory where the platform lets an app execute a file, and its path carries
 * a per-install hash that Dart cannot compute.
 *
 * Failure of the service is reported back as `false` rather than thrown: a
 * phone that refuses the service still runs the server, it just does not survive
 * the screen going off, and the app says so instead of refusing to start.
 */
class KeepAliveChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                val address = call.argument<String>("address").orEmpty()
                try {
                    KeepAliveService.start(context, address)
                    result.success(true)
                } catch (error: Exception) {
                    result.success(false)
                }
            }
            "stop" -> {
                KeepAliveService.stop(context)
                result.success(true)
            }
            "nativeLibraryDir" -> result.success(context.applicationInfo.nativeLibraryDir)
            else -> result.notImplemented()
        }
    }
}