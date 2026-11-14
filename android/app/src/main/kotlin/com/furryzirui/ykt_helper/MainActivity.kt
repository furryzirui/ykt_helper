package com.furryzirui.ykt_helper

import android.Manifest
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class MainActivity : FlutterActivity() {
    private var galleryRequest: GalleryRequest? = null
    private var permissionRequest: RuntimePermissionRequest? = null

    private class RuntimePermissionRequest(
        val permission: String,
        val result: MethodChannel.Result
    )

    private companion object {
        // Shared across activity recreation so a cancelled write can still clean up.
        val galleryExecutor = Executors.newSingleThreadExecutor()
    }

    private class GalleryRequest(
        val bytes: ByteArray,
        val name: String,
        val mimeType: String,
        val result: MethodChannel.Result
    ) {
        @Volatile var cancelled = false
    }

    private class SavedImage(initialUri: Uri? = null, val file: File? = null) {
        @Volatile var uri: Uri? = initialUri
            private set
        private var removed = false

        @Synchronized
        fun scanned(context: Context, scannedUri: Uri?) {
            if (scannedUri == null) return
            if (removed) {
                try {
                    context.contentResolver.delete(scannedUri, null, null)
                } catch (_: Exception) {
                    // The file was already removed after cancellation or scan timeout.
                }
            } else {
                uri = scannedUri
            }
        }

        @Synchronized
        fun remove(context: Context) {
            removed = true
            try {
                uri?.let { context.contentResolver.delete(it, null, null) }
            } catch (_: Exception) {
                // Still attempt file cleanup if deleting a legacy media row fails.
            }
            try {
                if (file != null) {
                    file.delete()
                    MediaScannerConnection.scanFile(context, arrayOf(file.path), null, null)
                }
            } catch (_: Exception) {
                // Preserve the original write error if cleanup also fails.
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ykt_helper/app_permissions"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "check" -> {
                    try {
                        result.success(mapOf(
                            "camera" to permissionStatus(checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED),
                            "notifications" to permissionStatus(notificationsAllowed()),
                            "photos" to if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) "notRequired" else
                                permissionStatus(checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED),
                            "battery" to permissionStatus(isIgnoringBatteryOptimizations())
                        ))
                    } catch (_: Exception) {
                        result.error("permission_check_failed", "无法读取应用权限状态，请重试", null)
                    }
                }
                "request" -> {
                    val permission = call.argument<String>("permission")
                    if (permission !in setOf("camera", "notifications", "photos", "battery")) {
                        result.error("invalid_permission", "无法识别此权限设置", null)
                    } else {
                        requestAppPermission(permission!!, result)
                    }
                }
                "openSettings" -> {
                    val permission = call.argument<String>("permission")
                    if (permission !in setOf("camera", "notifications", "photos", "battery")) {
                        result.error("invalid_permission", "无法识别此权限设置", null)
                    } else {
                        try {
                            openPermissionSettings(permission!!)
                            result.success(true)
                        } catch (_: Exception) {
                            result.error("settings_unavailable", "无法打开系统设置，请在系统设置中查找本应用", null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "ykt_helper/gallery"
        ).setMethodCallHandler { call, result ->
            if (call.method != "saveImage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (galleryRequest != null) {
                result.error("gallery_busy", "另一张图片仍在保存，请稍后重试", null)
                return@setMethodCallHandler
            }
            val bytes = call.argument<ByteArray>("bytes")
            val name = call.argument<String>("name")
            val mimeType = call.argument<String>("mimeType")
            if (bytes == null || bytes.isEmpty() || name.isNullOrBlank() ||
                mimeType !in setOf("image/png", "image/jpeg")) {
                result.error("invalid_image", "课件图片数据无效", null)
                return@setMethodCallHandler
            }
            val request = GalleryRequest(
                bytes,
                name.replace(Regex("[\\\\/:*?\"<>|\\p{Cntrl}]"), "_").take(180),
                mimeType!!,
                result
            )
            galleryRequest = request
            if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P &&
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
                PackageManager.PERMISSION_GRANTED) {
                galleryRequest = null
                result.error("permission_denied", "未授予相册存储权限，请在应用权限页面允许后重试", null)
            } else {
                saveGalleryImage(request)
            }
        }
    }

    private fun notificationsAllowed(): Boolean {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = manager.getNotificationChannel("flutter_background")
        val channelAllowed = channel?.importance != NotificationManager.IMPORTANCE_NONE
        val groupAllowed = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            channel?.group?.let { manager.getNotificationChannelGroup(it)?.isBlocked } != true
        } else true
        return manager.areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            channelAllowed && groupAllowed
    }

    private fun isIgnoringBatteryOptimizations() =
        (getSystemService(Context.POWER_SERVICE) as PowerManager)
            .isIgnoringBatteryOptimizations(packageName)

    private fun permissionGranted(permission: String): Boolean = when (permission) {
        "camera" -> checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        "notifications" -> notificationsAllowed()
        "photos" -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q ||
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        "battery" -> isIgnoringBatteryOptimizations()
        else -> false
    }

    private fun openPermissionSettings(permission: String) {
        val intent = if (permission == "notifications") {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
        } else {
            // Android exposes no standard, portable app-specific battery editor.
            // Use the same single-app detail page regardless of current exemption;
            // OEMs may add a battery section there. Never send users to all apps.
            applicationSettingsIntent()
        }
        try {
            startActivity(intent)
        } catch (error: Exception) {
            if (permission != "notifications") throw error
            startActivity(applicationSettingsIntent())
        }
    }

    private fun requestAppPermission(permission: String, result: MethodChannel.Result) {
        if (permissionRequest != null) {
            result.error("permission_busy", "另一项权限申请尚未完成", null)
            return
        }
        try {
            if (permissionGranted(permission)) {
                result.success(true)
                return
            }
            val runtime = when (permission) {
                "camera" -> Manifest.permission.CAMERA
                "photos" -> if (Build.VERSION.SDK_INT <= Build.VERSION_CODES.P)
                    Manifest.permission.WRITE_EXTERNAL_STORAGE else null
                "notifications" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                    Manifest.permission.POST_NOTIFICATIONS else null
                else -> null
            }
            val history = getSharedPreferences("permission_requests", Context.MODE_PRIVATE)
            if (runtime == null ||
                (history.getBoolean("blocked:$permission", false) && !shouldShowRequestPermissionRationale(runtime))) {
                openPermissionSettings(permission)
                result.success(false)
                return
            }
            permissionRequest = RuntimePermissionRequest(permission, result)
            try {
                requestPermissions(arrayOf(runtime), 8301)
            } catch (_: Exception) {
                permissionRequest = null
                openPermissionSettings(permission)
                result.success(false)
            }
        } catch (_: Exception) {
            permissionRequest = null
            result.error("permission_unavailable", "无法申请权限，请在应用权限中重试", null)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != 8301) return
        val pending = permissionRequest ?: return
        permissionRequest = null
        // An ordinary denial ends this attempt. It does not immediately open
        // settings. A later user-confirmed attempt can use the permanent-denial
        // fallback if Android no longer permits another runtime dialog.
        try {
            val granted = grantResults.isNotEmpty() && permissionGranted(pending.permission)
            if (grantResults.isNotEmpty()) {
                val permanentlyDenied = !granted && permissions.isNotEmpty() &&
                    !shouldShowRequestPermissionRationale(permissions[0])
                getSharedPreferences("permission_requests", Context.MODE_PRIVATE).edit()
                    .putBoolean("blocked:${pending.permission}", permanentlyDenied).apply()
            }
            pending.result.success(granted)
        } catch (_: Exception) {
            pending.result.error("permission_check_failed", "无法读取授权结果，请重试", null)
        }
    }

    private fun permissionStatus(granted: Boolean) = if (granted) "granted" else "denied"

    private fun applicationSettingsIntent() = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
        .setData(Uri.parse("package:$packageName"))

    @Suppress("DEPRECATION")
    private fun saveGalleryImage(request: GalleryRequest) {
        val context = applicationContext
        val task = Runnable {
            var image: SavedImage? = null
            try {
                if (request.cancelled) throw IOException("保存已取消")
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val values = ContentValues().apply {
                        put(MediaStore.Images.Media.DISPLAY_NAME, request.name)
                        put(MediaStore.Images.Media.MIME_TYPE, request.mimeType)
                        put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/ykt_helper")
                        put(MediaStore.Images.Media.IS_PENDING, 1)
                    }
                    val uri = context.contentResolver.insert(
                        MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values
                    ) ?: throw IOException("无法创建相册图片")
                    image = SavedImage(initialUri = uri)
                    val stream = context.contentResolver.openOutputStream(uri, "w")
                        ?: throw IOException("无法写入相册图片")
                    stream.use { it.write(request.bytes); it.flush() }
                    if (request.cancelled) throw IOException("保存已取消")
                    val published = context.contentResolver.update(uri, ContentValues().apply {
                        put(MediaStore.Images.Media.IS_PENDING, 0)
                    }, null, null)
                    if (published <= 0) throw IOException("系统未确认图片已加入相册")
                } else {
                    val directory = File(
                        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                        "ykt_helper"
                    )
                    if (!directory.isDirectory && !directory.mkdirs()) {
                        throw IOException("无法创建相册目录，请检查存储空间")
                    }
                    val extension = if (request.mimeType == "image/png") ".png" else ".jpg"
                    val prefix = request.name.removeSuffix(extension).take(120).padEnd(3, '_')
                    val file = File.createTempFile("$prefix-", extension, directory)
                    val savedImage = SavedImage(file = file)
                    image = savedImage
                    file.outputStream().use { it.write(request.bytes); it.flush() }
                    if (request.cancelled) throw IOException("保存已取消")
                    val scanned = CountDownLatch(1)
                    MediaScannerConnection.scanFile(
                        context, arrayOf(file.path), arrayOf(request.mimeType)
                    ) { _, uri ->
                        savedImage.scanned(context, uri)
                        scanned.countDown()
                    }
                    if (!scanned.await(15, TimeUnit.SECONDS) || savedImage.uri == null) {
                        throw IOException("系统未确认图片已加入相册")
                    }
                }
                val saved = image
                if (request.cancelled) throw IOException("保存已取消")
                runOnUiThread {
                    if (request.cancelled || galleryRequest !== request) {
                        galleryExecutor.execute { saved?.remove(context) }
                    } else {
                        galleryRequest = null
                        request.result.success(true)
                    }
                }
            } catch (error: Exception) {
                image?.remove(context)
                runOnUiThread {
                    if (galleryRequest === request) {
                        galleryRequest = null
                        val message = if (error is SecurityException) {
                            "没有相册存储权限，请在系统设置中允许后重试"
                        } else {
                            "保存到系统相册失败，请检查存储空间后重试"
                        }
                        request.result.error("gallery_write_failed", message, null)
                    }
                }
            }
        }
        try {
            galleryExecutor.execute(task)
        } catch (_: Exception) {
            if (galleryRequest === request) {
                galleryRequest = null
                request.result.error("gallery_unavailable", "暂时无法保存到系统相册，请重试", null)
            }
        }
    }

    override fun onDestroy() {
        permissionRequest?.result?.error("activity_destroyed", "权限申请已中断，请返回后重试", null)
        permissionRequest = null
        galleryRequest?.let {
            it.cancelled = true
            it.result.error("activity_destroyed", "保存已中断，请返回相册确认已保存的图片后重试", null)
        }
        galleryRequest = null
        super.onDestroy()
    }
}
