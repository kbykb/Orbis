package com.orbising.orbis

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.core.content.ContextCompat

class InteractionNotifier(private val context: Context) {
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val preferences = context.getSharedPreferences("orbis_reply_completion_receipts", Context.MODE_PRIVATE)
    private val replyReceipts = ReplyCompletionReceipts(preferences.getStringSet("seen", emptySet()).orEmpty())

    init {
        notifications.createNotificationChannel(NotificationChannel(
            CHANNEL_ID,
            L10n.tr("Orbis 交互请求"),
            NotificationManager.IMPORTANCE_HIGH,
        ))
        notifications.createNotificationChannel(NotificationChannel(
            REPLY_CHANNEL_ID, L10n.tr("回复完成"), NotificationManager.IMPORTANCE_DEFAULT,
        ))
    }

    internal fun showReplyCompleted(reply: ConfirmedReplyCompletion, target: NotificationOpenTarget?) {
        if (!replyReceipts.claim(reply.identity)) return
        preferences.edit().putStringSet("seen", replyReceipts.snapshot()).apply()
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val intent = contentIntent(target)
        notifications.notify(reply.identity, 0, Notification.Builder(context, REPLY_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_orbis).setContentTitle(L10n.tr("回复完成"))
            .setContentText(reply.runtimeName).setContentIntent(intent).setAutoCancel(true).build())
    }

    internal fun show(runtimeName: String, request: PendingInteraction, target: NotificationOpenTarget?) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            return
        }
        val intent = contentIntent(target)
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_orbis)
            .setContentTitle(request.title)
            .setContentText("$runtimeName • ${request.extensionId}")
            .setContentIntent(intent)
            .setAutoCancel(true)
            .build()
        notifications.notify("${target?.intentData.orEmpty()}:${request.requestId}", 0, notification)
    }

    private fun contentIntent(target: NotificationOpenTarget?): PendingIntent = PendingIntent.getActivity(
        context, 0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP).apply {
            action = OPEN_NOTIFICATION
            // Intent extras do not distinguish PendingIntents. Give every target its own data URI.
            data = target?.let { Uri.parse(it.intentData) }
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private companion object {
        // Stable Android channel ID preserves the user's existing notification settings.
        const val CHANNEL_ID = "pi_remote_interactions"
        const val REPLY_CHANNEL_ID = "orbis_reply_completion"
    }
}

internal const val OPEN_NOTIFICATION = "com.orbising.orbis.OPEN_NOTIFICATION"

internal fun Intent.notificationOpenTarget(): NotificationOpenTarget? {
    if (action != OPEN_NOTIFICATION) return null
    val uri = data ?: return null
    if (uri.scheme != "orbis" || uri.authority != "notification" || uri.query != null || uri.fragment != null) return null
    val fields = uri.pathSegments
    if (fields.size != 4) return null
    return NotificationOpenTarget.create(fields[0], fields[1], fields[2], fields[3])
}
