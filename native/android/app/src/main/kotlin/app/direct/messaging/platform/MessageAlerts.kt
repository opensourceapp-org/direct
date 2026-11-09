package app.direct.messaging.platform

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import app.direct.core.node.InboundAlert
import app.direct.messaging.MainActivity
import app.direct.messaging.R

/** Local notifications for inbound messages. The payload never leaves this phone. */
object MessageAlerts {
    const val EXTRA_PEER = "app.direct.messaging.open_peer"

    private const val CHANNEL = "direct.messages"
    private const val PRESENCE_CHANNEL = "direct.presence"

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < 26) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "Messages", NotificationManager.IMPORTANCE_HIGH).apply {
                    description = "New DIRECT messages while the app is in the background."
                    enableVibration(true)
                },
            )
        }
        if (manager.getNotificationChannel(PRESENCE_CHANNEL) == null) {
            manager.createNotificationChannel(
                NotificationChannel(PRESENCE_CHANNEL, "Online", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Shown while DIRECT stays connected with the screen off."
                    setSound(null, null)
                    enableVibration(false)
                },
            )
        }
    }

    fun canNotify(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 33) return true
        return ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    fun show(context: Context, alert: InboundAlert) {
        ensureChannels(context)
        if (!canNotify(context)) return
        val open = PendingIntent.getActivity(
            context,
            alert.threadId.hashCode(),
            Intent(context, MainActivity::class.java)
                .putExtra(EXTRA_PEER, alert.threadId)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_stat_direct)
            .setContentTitle(alert.title)
            .setContentText(alert.body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(alert.body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()
        NotificationManagerCompat.from(context).notify(alert.threadId.hashCode(), notification)
    }

    fun cancel(context: Context, threadId: String) {
        NotificationManagerCompat.from(context).cancel(threadId.hashCode())
    }

    internal const val PRESENCE = PRESENCE_CHANNEL
}
