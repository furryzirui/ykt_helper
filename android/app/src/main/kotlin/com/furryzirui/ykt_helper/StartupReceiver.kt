package com.furryzirui.ykt_helper

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class StartupReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED)) return
        if (!YktApplication.mayRestore(context)) return
        try {
            ClassroomRuntimeService.start(context, restoring = true)
        } catch (_: Exception) {
            // User-facing launches show background failure through AppController.
            // Never launch an Activity from a boot/background receiver.
        }
    }
}
