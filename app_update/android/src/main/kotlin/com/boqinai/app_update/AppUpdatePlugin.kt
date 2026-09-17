package com.boqinai.app_update

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File

class AppUpdatePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingDownload: Pair<MethodCall, MethodChannel.Result>? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "app_update")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getUpdateContext" -> getUpdateContext(result)
            "startDownload" -> startDownload(call, result)
            "getDownloadProgress" -> getDownloadProgress(call, result)
            "cancelDownload" -> cancelDownload(call, result)
            "openApk" -> openApk(call, result)
            else -> result.notImplemented()
        }
    }

    private fun getUpdateContext(result: MethodChannel.Result) {
        try {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                info.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                info.versionCode.toLong()
            }
            val deviceId = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ANDROID_ID,
            ).orEmpty()
            result.success(mapOf(
                "packageName" to context.packageName,
                "versionCode" to versionCode,
                "deviceId" to deviceId,
            ))
        } catch (error: Exception) {
            result.error("update_context_failed", error.message, null)
        }
    }

    private fun startDownload(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            val currentActivity = activity
            if (currentActivity == null) {
                result.error("notification_permission_required", "Notification permission is required", null)
                return
            }
            if (pendingDownload != null) {
                result.error("download_pending", "Another download is waiting for permission", null)
                return
            }
            pendingDownload = call to result
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
            return
        }
        enqueueDownload(call, result)
    }

    private fun enqueueDownload(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        val version = call.argument<String>("version")
        val wifiOnly = call.argument<Boolean>("wifiOnly") == true
        if (url.isNullOrBlank() || version.isNullOrBlank()) {
            result.error("invalid_args", "URL or version is empty", null)
            return
        }
        try {
            val directory = context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: throw IllegalStateException("External downloads directory is unavailable")
            val safeVersion = version.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val destination = File(directory, "app_update_$safeVersion.apk")
            if (destination.exists()) destination.delete()
            val id = UpdateDownloadService.enqueue(context, url, version, destination, wifiOnly)
            result.success(mapOf("downloadId" to id, "filePath" to destination.absolutePath))
        } catch (error: Exception) {
            result.error("download_failed", error.message, null)
        }
    }

    private fun getDownloadProgress(call: MethodCall, result: MethodChannel.Result) {
        val id = call.longArgument("downloadId")
        if (id == null) {
            result.error("invalid_id", "Invalid download ID", null)
            return
        }
        try {
            val progress = UpdateDownloadService.progress(context, id)
            if (progress == null) result.error("not_found", "Download task not found", null)
            else result.success(progress)
        } catch (error: Exception) {
            result.error("query_failed", error.message, null)
        }
    }

    private fun cancelDownload(call: MethodCall, result: MethodChannel.Result) {
        val id = call.longArgument("downloadId")
        if (id == null) {
            result.error("invalid_id", "Invalid download ID", null)
            return
        }
        try {
            result.success(UpdateDownloadService.cancel(context, id))
        } catch (error: Exception) {
            result.error("cancel_failed", error.message, null)
        }
    }

    private fun openApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("invalid_path", "APK path is empty", null)
            return
        }
        try {
            val apk = File(path)
            if (!apk.isFile) {
                result.error("file_not_found", "Downloaded APK does not exist", null)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !context.packageManager.canRequestPackageInstalls()
            ) {
                openUnknownSourcesSettings()
                result.error("install_permission_required", "Allow this app to install unknown apps, then retry", null)
                return
            }
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.app_update.fileprovider",
                apk,
            )
            context.startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, APK_MIME_TYPE)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("no_installer", "No app can open APK files", null)
        } catch (error: Exception) {
            result.error("open_failed", error.message, null)
        }
    }

    private fun openUnknownSourcesSettings() {
        val flags = Intent.FLAG_ACTIVITY_NEW_TASK
        try {
            context.startActivity(Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${context.packageName}"),
            ).addFlags(flags))
        } catch (_: ActivityNotFoundException) {
            try {
                context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).addFlags(flags))
            } catch (_: ActivityNotFoundException) {
                context.startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS).addFlags(flags))
            }
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity(failPending = false)
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
    override fun onDetachedFromActivity() = detachActivity(failPending = true)

    private fun detachActivity(failPending: Boolean) {
        if (failPending) {
            failPendingDownload(
                "activity_detached",
                "Activity was detached before notification permission result",
            )
        }
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return false
        val pending = pendingDownload ?: return true
        pendingDownload = null
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            enqueueDownload(pending.first, pending.second)
        } else {
            pending.second.error("notification_permission_denied", "Notification permission was denied", null)
        }
        return true
    }

    private fun MethodCall.longArgument(name: String): Long? = when (val value = argument<Any>(name)) {
        is Int -> value.toLong()
        is Long -> value
        is String -> value.toLongOrNull()
        else -> null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        failPendingDownload(
            "engine_detached",
            "Flutter engine was detached before notification permission result",
        )
        channel.setMethodCallHandler(null)
    }

    private fun failPendingDownload(code: String, message: String) {
        val pending = pendingDownload ?: return
        pendingDownload = null
        pending.second.error(code, message, null)
    }

    private companion object {
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val NOTIFICATION_PERMISSION_REQUEST = 7412
    }
}
