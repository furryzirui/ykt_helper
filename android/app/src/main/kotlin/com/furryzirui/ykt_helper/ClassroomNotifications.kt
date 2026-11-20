package com.furryzirui.ykt_helper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/** Registered with the shared engine, including receiver-started headless work. */
internal class ClassroomNotifications(
    private val context: Context,
    messenger: BinaryMessenger,
    private val visible: () -> Boolean
) {
    private val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private val channel = MethodChannel(messenger, "ykt_helper/classroom_notifications")

    init {
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "课堂提醒", NotificationManager.IMPORTANCE_DEFAULT
        ))
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "show" -> {
                        val key = call.argument<String>("key")
                        val title = call.argument<String>("title")
                        val body = call.argument<String>("body")
                        val lessonId = call.argument<String>("lessonId")
                        val problemId = call.argument<String>("problemId")
                        if (key.isNullOrEmpty() || title.isNullOrEmpty() || body == null ||
                            lessonId.isNullOrEmpty() || problemId.isNullOrEmpty() || visible() ||
                            !RuntimePermissions.classroomNotificationsAllowed(context)) {
                            result.success(false)
                        } else {
                            val tag = TAG_PREFIX + key
                            val intent = Intent(context, MainActivity::class.java)
                                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                                // A unique explicit action keeps PendingIntents
                                // separate without creating a Flutter deeplink.
                                .setAction("${context.packageName}.CLASSROOM_REMINDER.$key")
                                .putExtra("lessonId", lessonId)
                                .putExtra("problemId", problemId)
                            val pending = PendingIntent.getActivity(context, 0, intent,
                                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                            val notification = Notification.Builder(context, CHANNEL_ID)
                                .setContentTitle(title.take(120))
                                .setContentText(body.take(500))
                                .setStyle(Notification.BigTextStyle().bigText(body.take(500)))
                                .setSmallIcon(R.drawable.ic_background)
                                .setContentIntent(pending)
                                .setAutoCancel(true)
                                .setOnlyAlertOnce(true)
                                .setCategory(Notification.CATEGORY_REMINDER)
                                .setVisibility(Notification.VISIBILITY_PRIVATE)
                                .build()
                            manager.notify(tag, NOTIFICATION_ID, notification)
                            result.success(true)
                        }
                    }
                    "cancel" -> {
                        call.argument<String>("key")?.let { manager.cancel(TAG_PREFIX + it, NOTIFICATION_ID) }
                        result.success(null)
                    }
                    "cancelAll" -> {
                        manager.activeNotifications.filter { it.tag?.startsWith(TAG_PREFIX) == true }
                            .forEach { manager.cancel(it.tag, it.id) }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                if (call.method == "show") result.success(false)
                else result.success(null)
            }
        }
    }

    companion object {
        const val CHANNEL_ID = "classroom_reminders"
        private const val TAG_PREFIX = "ykt_classroom:"
        private const val NOTIFICATION_ID = 2
    }
}
