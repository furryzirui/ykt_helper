package com.furryzirui.ykt_helper

import android.app.Application
import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** A single engine owns credentials, classroom sockets and answer timers. */
class YktApplication : Application() {
    private var engine: FlutterEngine? = null
    private var startupChannel: MethodChannel? = null
    private var foregroundVisible = false

    @Synchronized
    fun engine(background: Boolean): FlutterEngine {
        engine?.let { return it }
        if (!background) {
            // Only a new, user-launched process clears an earlier manual stop.
            // Reattaching an Activity to a running headless engine does not.
            prefs(this).edit().putBoolean("suspended", false).commit()
        }
        // FlutterEngine's automatic plugin registration includes SecureStorage,
        // whose Android implementation uses only applicationContext.
        val created = FlutterEngine(this)
        engine = created
        FlutterEngineCache.getInstance().put(ENGINE_ID, created)
        val messenger = created.dartExecutor.binaryMessenger
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
        MethodChannel(messenger, "ykt_helper/background_runtime").setMethodCallHandler { call, result ->
            if (call.method != "setEnabled") {
                result.notImplemented()
            } else {
                try {
                    val enabled = call.argument<Boolean>("enabled") == true
                    if (enabled && !RuntimePermissions.backgroundAllowed(this)) {
                        ClassroomRuntimeService.stop(this)
                        result.success(false)
                    } else {
                        if (enabled) {
                            ClassroomRuntimeService.start(this) { success -> result.success(success) }
                        } else {
                            ClassroomRuntimeService.stop(this)
                            result.success(true)
                        }
                    }
                } catch (_: Exception) {
                    result.success(false)
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
        if (visible) startupChannel?.invokeMethod("foreground", null)
    }

    companion object {
        const val ENGINE_ID = "ykt_helper_shared_engine"
        fun prefs(context: Context) = context.getSharedPreferences("ykt_autostart", Context.MODE_PRIVATE)
        fun mayRestore(context: Context): Boolean {
            val state = prefs(context)
            return state.getBoolean("enabled", false) && state.getBoolean("eligible", false) &&
                !state.getBoolean("suspended", false) && RuntimePermissions.backgroundAllowed(context)
        }
    }
}
