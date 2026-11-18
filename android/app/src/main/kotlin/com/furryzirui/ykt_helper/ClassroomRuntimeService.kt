package com.furryzirui.ykt_helper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

class ClassroomRuntimeService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var running = false
    private val deadlineCheck = Runnable { armDeadline() }
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val restoring = intent == null || intent.getBooleanExtra("restoring", false)
        val newSession = !running
        val allowed = RuntimePermissions.backgroundAllowed(this)
        val canRestore = !restoring || if (newSession) {
            YktApplication.mayStartNewSession(this)
        } else YktApplication.mayRestore(this)
        val decision = ServiceStartPolicy.decide(running, restoring, canRestore, allowed)
        // A countdown belongs to the actual running service. A permitted boot
        // or process-recovery start begins a fresh unlimited session, while a
        // timer that already suspended automation must remain suspended.
        if (decision == ServiceStartPolicy.Decision.NEW_SESSION) {
            YktApplication.configureDeadline(this, null)
        }
        val expired = YktApplication.deadlineExpired(this)
        if (expired || decision == ServiceStartPolicy.Decision.DENIED) {
            lastReason = if (expired) "deadline" else if (!allowed) "permission" else "stopped"
            running = false
            finishStart(false)
            (application as YktApplication).runtimeChanged()
            stopSelf()
            if (expired) (application as YktApplication).requestBackgroundExit()
            return START_NOT_STICKY
        }
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(NotificationChannel(
            CHANNEL_ID, "后台课堂", NotificationManager.IMPORTANCE_LOW
        ).apply { setShowBadge(false) })
        val launch = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(this, 0, launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ykt_helper")
            .setContentText("正在监控课堂，按设置自动签到和答题")
            .setSmallIcon(R.drawable.ic_background).setContentIntent(pending).setOngoing(true).build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else startForeground(NOTIFICATION_ID, notification)
            if (wakeLock == null) {
                wakeLock = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                    .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ykt_helper:classroom").apply {
                        setReferenceCounted(false)
                        @Suppress("WakelockTimeout")
                        acquire()
                    }
            }
            if (wifiLock == null) {
                @Suppress("DEPRECATION")
                wifiLock = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                    .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "ykt_helper:classroom").apply {
                        setReferenceCounted(false)
                        acquire()
                    }
            }
            // The actual main()/AppController reloads settings and credentials.
            // UI entry later reuses this engine, never a second automation owner.
            (application as YktApplication).engine(background = restoring)
        } catch (_: Exception) {
            running = false
            lastReason = "startFailed"
            finishStart(false)
            (application as YktApplication).runtimeChanged()
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        lastReason = null
        armDeadline()
        if (!running) return START_NOT_STICKY
        (application as YktApplication).runtimeChanged()
        finishStart(true)
        return if (YktApplication.mayRestore(this)) START_STICKY else START_NOT_STICKY
    }

    private fun armDeadline() {
        handler.removeCallbacks(deadlineCheck)
        if (!running) return
        val remaining = YktApplication.deadlineRemaining(this) ?: return
        if (remaining <= 0) {
            YktApplication.deadlineExpired(this)
            running = false
            lastReason = "deadline"
            finishStart(false)
            (application as YktApplication).runtimeChanged()
            stopSelf()
            (application as YktApplication).requestBackgroundExit()
            return
        }
        // Recheck the wall clock at least once a minute as well as at expiry.
        // elapsedRealtime handles clock rollback; no exact-alarm permission is
        // needed because this foreground service already holds a CPU wake lock.
        handler.postDelayed(deadlineCheck, minOf(remaining, 60_000L))
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Ordinary task removal keeps the running foreground service. Android
        // force-stop and OEM restrictions cannot be bypassed by this service.
        if (!YktApplication.mayRestore(this)) stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacks(deadlineCheck)
        running = false
        if (lastReason == null) lastReason = "stopped"
        wakeLock?.let { if (it.isHeld) it.release() }
        wifiLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (instance === this) instance = null
        finishStart(false)
        (application as YktApplication).runtimeChanged()
        super.onDestroy()
    }

    companion object {
        // Reuse the previous notification category so a user's disabled category
        // stays disabled after upgrading.
        const val CHANNEL_ID = "flutter_background"
        private const val NOTIFICATION_ID = 1
        private val starts = mutableListOf<(Boolean) -> Unit>()
        private val handler = Handler(Looper.getMainLooper())
        private var instance: ClassroomRuntimeService? = null
        private var lastReason: String? = null

        fun isRunning(): Boolean = instance?.running == true

        private fun finishStart(success: Boolean) {
            val pending = starts.toList()
            starts.clear()
            pending.forEach { it(success) }
        }

        fun start(context: Context, restoring: Boolean = false, callback: ((Boolean) -> Unit)? = null) {
            callback?.let { starts.add(it) }
            try {
                context.startForegroundService(Intent(context, ClassroomRuntimeService::class.java)
                    .putExtra("restoring", restoring))
                if (callback != null) handler.postDelayed({
                    if (starts.remove(callback)) callback(false)
                }, 5000)
            } catch (error: Exception) {
                callback?.let { starts.remove(it) }
                throw error
            }
        }
        fun deadlineChanged(context: Context) {
            val expired = YktApplication.deadlineExpired(context)
            if (!expired && lastReason == "deadline") lastReason = "stopped"
            val service = instance
            if (service != null) {
                service.armDeadline()
            } else if (expired) {
                lastReason = "deadline"
            }
        }

        fun status(context: Context): Map<String, Any?> = mapOf(
            "enabled" to (instance?.running == true && !YktApplication.deadlineExpired(context)),
            "mode" to "native",
            "deadlineEpochMs" to YktApplication.deadline(context)?.epochMs,
            "reason" to if (YktApplication.deadlineExpired(context)) "deadline" else lastReason
        )

        fun stop(context: Context, reason: String = "stopped") {
            val wasRunning = instance?.running == true
            val previousReason = lastReason
            lastReason = if (YktApplication.deadlineExpired(context)) "deadline" else reason
            instance?.let {
                handler.removeCallbacks(it.deadlineCheck)
                it.running = false
            }
            finishStart(false)
            context.stopService(Intent(context, ClassroomRuntimeService::class.java))
            if (wasRunning || lastReason != previousReason) {
                (context.applicationContext as? YktApplication)?.runtimeChanged()
            }
        }
    }
}
