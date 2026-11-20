package com.furryzirui.ykt_helper

import android.app.Application
import android.app.ActivityManager
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** A single engine owns credentials, classroom sockets and answer timers. */
class YktApplication : Application() {
    private var engine: FlutterEngine? = null
    private var startupChannel: MethodChannel? = null
    private var runtimeChannel: MethodChannel? = null
    private var classroomNotifications: ClassroomNotifications? = null
    private var foregroundVisible = false
    private var windowVisible = false
    private val exitHandler = Handler(Looper.getMainLooper())
    private var exitPending = false

    @Synchronized
    fun engine(background: Boolean): FlutterEngine {
        engine?.let { return it }
        if (!background) {
            // Only a new, user-launched process clears an earlier manual stop.
            // Reattaching an Activity to a running headless engine does not.
            if (!ClassroomRuntimeService.isRunning()) configureDeadline(this, null)
            prefs(this).edit().putBoolean("suspended", false).commit()
        }
        // FlutterEngine's automatic plugin registration includes SecureStorage,
        // whose Android implementation uses only applicationContext.
        val created = FlutterEngine(this)
        engine = created
        FlutterEngineCache.getInstance().put(ENGINE_ID, created)
        val messenger = created.dartExecutor.binaryMessenger
        classroomNotifications = ClassroomNotifications(this, messenger) {
            foregroundVisible || windowVisible
        }
        startupChannel = MethodChannel(messenger, "ykt_helper/app_autostart").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "configure" -> {
                            val enabled = call.argument<Boolean>("enabled") == true
                            val eligible = call.argument<Boolean>("eligible") == true
                            if (!prefs(this@YktApplication).edit()
                                    .putBoolean("enabled", enabled)
                                    .putBoolean("eligible", eligible).commit()) {
                                result.error("autostart_save_failed", "无法保存应用自启动设置", null)
                            } else result.success(null)
                        }
                        "setSuspended" -> {
                            if (!prefs(this@YktApplication).edit().putBoolean(
                                    "suspended", call.argument<Boolean>("suspended") == true
                                ).commit()) {
                                result.error("autostart_save_failed", "无法保存服务暂停状态", null)
                            } else result.success(null)
                        }
                        "status" -> result.success(mapOf(
                            "enabled" to prefs(this@YktApplication).getBoolean("enabled", false),
                            "suspended" to prefs(this@YktApplication).getBoolean("suspended", false)
                        ))
                        "isForeground" -> result.success(foregroundVisible)
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    result.error("autostart_unavailable", "应用自启动设置不可用", null)
                }
            }
        }
        runtimeChannel = MethodChannel(messenger, "ykt_helper/background_runtime").apply {
            setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "configure", "setEnabled" -> {
                            val arguments = call.arguments as? Map<*, *>
                            if (arguments?.containsKey("deadlineEpochMs") == true) {
                                val deadline = arguments["deadlineEpochMs"]
                                require(deadline == null || deadline is Int || deadline is Long) {
                                    "Invalid service deadline"
                                }
                                configureDeadline(this@YktApplication, (deadline as? Number)?.toLong())
                            }
                            ClassroomRuntimeService.deadlineChanged(this@YktApplication)
                            if (call.method == "configure") {
                                result.success(null)
                            } else if (call.argument<Boolean>("enabled") == true) {
                                if (deadlineExpired(this@YktApplication)) {
                                    ClassroomRuntimeService.stop(this@YktApplication, "deadline")
                                    result.success(false)
                                } else if (!RuntimePermissions.backgroundAllowed(this@YktApplication)) {
                                    ClassroomRuntimeService.stop(this@YktApplication, "permission")
                                    result.success(false)
                                } else {
                                    ClassroomRuntimeService.start(this@YktApplication) { success -> result.success(success) }
                                }
                            } else {
                                ClassroomRuntimeService.stop(this@YktApplication)
                                result.success(true)
                            }
                        }
                        "status" -> {
                            ClassroomRuntimeService.deadlineChanged(this@YktApplication)
                            result.success(ClassroomRuntimeService.status(this@YktApplication))
                        }
                        "exitApplication" -> result.success(requestBackgroundExit())
                        else -> result.notImplemented()
                    }
                } catch (_: Exception) {
                    when (call.method) {
                        "setEnabled" -> {
                            ClassroomRuntimeService.stop(this@YktApplication, "startFailed")
                            result.success(false)
                        }
                        else -> result.error("runtime_unavailable", "后台服务设置不可用，请重试", null)
                    }
                }
            }
        }
        installHeadlessPermissions(created)
        created.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
            if (background) listOf("--background-auto-start") else emptyList()
        )
        return created
    }

    // Restored after Activity detach: headless work may read authorization, but
    // may never launch a permission dialog or a settings page.
    fun installHeadlessPermissions(target: FlutterEngine) {
        MethodChannel(target.dartExecutor.binaryMessenger, "ykt_helper/app_permissions")
            .setMethodCallHandler { call, result ->
                if (call.method == "check") {
                    result.success(RuntimePermissions.states(this))
                } else result.error("activity_required", "请打开应用后管理权限", null)
            }
    }

    fun foreground(visible: Boolean) {
        foregroundVisible = visible
        if (visible) {
            ClassroomRuntimeService.deadlineChanged(this)
            startupChannel?.invokeMethod("foreground", null)
        }
    }

    fun runtimeChanged() {
        runtimeChannel?.invokeMethod("stateChanged", ClassroomRuntimeService.status(this))
    }

    fun windowVisible(visible: Boolean) {
        // onPause also occurs for permission sheets and notification shade;
        // only onStop means the application's Activity is no longer visible.
        windowVisible = visible
    }

    private fun mayExitBackground(): Boolean {
        return try {
            val process = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(process)
            ServiceExitPolicy.canExit(windowVisible, foregroundVisible, process.importance,
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE,
                ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND_SERVICE)
        } catch (_: Exception) {
            // If visibility cannot be verified, keep the process alive.
            false
        }
    }

    fun requestBackgroundExit(): Boolean {
        if (!mayExitBackground()) return false
        if (exitPending) return true
        exitPending = true
        exitHandler.postDelayed({
            exitPending = false
            // Give Dart time to flush the service session and close sockets,
            // but do not rely on its callback to enforce a native deadline.
            // Returning to any visible Activity cancels process termination.
            if (!mayExitBackground()) return@postDelayed
            prefs(this).edit().putBoolean("suspended", true).commit()
            ClassroomRuntimeService.stop(this)
            val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            manager.appTasks.forEach { task ->
                try { task.finishAndRemoveTask() } catch (_: Exception) { /* Continue cleanup. */ }
            }
            // No Activity can resume between the visibility check and exit:
            // both lifecycle callbacks and this final check run on main.
            if (!mayExitBackground()) return@postDelayed
            Process.killProcess(Process.myPid())
        }, 750)
        return true
    }

    companion object {
        const val ENGINE_ID = "ykt_helper_shared_engine"
        fun prefs(context: Context) = context.getSharedPreferences("ykt_autostart", Context.MODE_PRIVATE)
        fun mayRestore(context: Context): Boolean {
            if (deadlineExpired(context)) return false
            return mayStartNewSession(context)
        }

        fun mayStartNewSession(context: Context): Boolean {
            val state = prefs(context)
            return ServiceStartPolicy.restorationAllowed(
                state.getBoolean("enabled", false), state.getBoolean("eligible", false),
                state.getBoolean("suspended", false), RuntimePermissions.backgroundAllowed(context)
            )
        }

        private fun bootCount(context: Context): Int = try {
            Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
        } catch (_: Exception) { -1 }

        internal fun deadline(context: Context): ServiceDeadline? {
            val state = prefs(context)
            if (!state.contains("serviceDeadlineEpochMs")) return null
            return ServiceDeadline(
                state.getLong("serviceDeadlineEpochMs", 0),
                state.getLong("serviceDeadlineElapsedMs", 0),
                state.getInt("serviceDeadlineBootCount", -1)
            )
        }

        fun configureDeadline(context: Context, epochMs: Long?) {
            val state = prefs(context)
            val editor = state.edit()
            if (epochMs == null) {
                editor.remove("serviceDeadlineEpochMs").remove("serviceDeadlineElapsedMs")
                    .remove("serviceDeadlineBootCount")
            } else {
                require(epochMs >= 0) { "Invalid service deadline" }
                val next = ServiceDeadline.configure(deadline(context), epochMs,
                    System.currentTimeMillis(), SystemClock.elapsedRealtime(), bootCount(context))
                editor.putLong("serviceDeadlineEpochMs", next.epochMs)
                    .putLong("serviceDeadlineElapsedMs", next.elapsedMs)
                    .putInt("serviceDeadlineBootCount", next.bootCount)
            }
            check(editor.commit()) { "Unable to save service deadline" }
        }

        fun deadlineRemaining(context: Context): Long? = deadline(context)?.remaining(
            System.currentTimeMillis(), SystemClock.elapsedRealtime(), bootCount(context))

        fun deadlineExpired(context: Context): Boolean {
            if (deadlineRemaining(context) != 0L) return false
            // Keep the expired deadline as well as the suspension bit. A later
            // process/boot cannot revive it even if persisting the bit fails.
            val state = prefs(context)
            if (!state.getBoolean("suspended", false)) {
                state.edit().putBoolean("suspended", true).commit()
            }
            return true
        }
    }
}
