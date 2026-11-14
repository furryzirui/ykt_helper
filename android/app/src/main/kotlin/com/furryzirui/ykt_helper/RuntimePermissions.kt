package com.furryzirui.ykt_helper

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager

object RuntimePermissions {
    private fun status(value: Boolean) = if (value) "granted" else "denied"
    fun notificationsAllowed(context: Context): Boolean {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel(ClassroomRuntimeService.CHANNEL_ID)
        val groupAllowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            channel?.group?.let { manager.getNotificationChannelGroup(it)?.isBlocked } != true
        } else true
        return manager.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            channel?.importance != NotificationManager.IMPORTANCE_NONE && groupAllowed
    }
    fun batteryAllowed(context: Context) =
        (context.getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isIgnoringBatteryOptimizations(context.packageName)

    fun backgroundAllowed(context: Context) = notificationsAllowed(context) && batteryAllowed(context)

    fun states(context: Context) = mapOf(
        "camera" to status(context.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED),
        "notifications" to status(notificationsAllowed(context)),
        "photos" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) "notRequired" else
            status(context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED),
        "battery" to status(batteryAllowed(context)),
        // OEM auto-start allowlists have no public authorization query API.
        "autostart" to "needsConfirmation"
    )
}
