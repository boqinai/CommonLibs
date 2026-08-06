package com.boqinai.app_update

import android.app.DownloadManager
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class AppUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel

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
            result.success(
                mapOf(
                    "packageName" to context.packageName,
                    "versionCode" to versionCode,
                    "deviceId" to deviceId,
                ),
            )
        } catch (error: Exception) {
            result.error("update_context_failed", error.message, null)
        }
    }

    private fun startDownload(call: MethodCall, result: MethodChannel.Result) {
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
            val fileName = "app_update_$safeVersion.apk"
            val destination = File(directory, fileName)
            if (destination.exists()) destination.delete()

            val appName = context.applicationInfo.loadLabel(context.packageManager)
            val request = DownloadManager.Request(Uri.parse(url)).apply {
                setTitle("$appName 更新 v$version")
                setDescription("正在后台下载最新版…")
                setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
                setDestinationInExternalFilesDir(
                    context,
                    Environment.DIRECTORY_DOWNLOADS,
                    fileName,
                )
                setMimeType(APK_MIME_TYPE)
                if (wifiOnly) {
                    setAllowedNetworkTypes(DownloadManager.Request.NETWORK_WIFI)
                }
            }
            val id = downloadManager.enqueue(request)
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
            downloadManager.query(DownloadManager.Query().setFilterById(id)).use { cursor ->
                if (!cursor.moveToFirst()) {
                    result.error("not_found", "Download task not found", null)
                    return
                }
                result.success(
                    mapOf(
                        "status" to cursor.getInt(
                            cursor.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS),
                        ),
                        "bytesDownloaded" to cursor.getLong(
                            cursor.getColumnIndexOrThrow(
                                DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR,
                            ),
                        ),
                        "totalBytes" to cursor.getLong(
                            cursor.getColumnIndexOrThrow(
                                DownloadManager.COLUMN_TOTAL_SIZE_BYTES,
                            ),
                        ),
                    ),
                )
            }
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
        result.success(downloadManager.remove(id) > 0)
    }

    private fun openApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("invalid_path", "APK path is empty", null)
            return
        }
        try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            context.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
            result.error(
                "install_permission_required",
                "Allow this app to install unknown apps, then retry",
                null,
            )
            return
        }

            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.app_update.fileprovider",
                File(path),
            )
            context.startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, APK_MIME_TYPE)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
            result.success(true)
        } catch (error: ActivityNotFoundException) {
            result.error("no_installer", "No app can open APK files", null)
        } catch (error: Exception) {
            result.error("open_failed", error.message, null)
        }
    }

    private fun MethodCall.longArgument(name: String): Long? = when (val value = argument<Any>(name)) {
        is Int -> value.toLong()
        is Long -> value
        is String -> value.toLongOrNull()
        else -> null
    }

    private val downloadManager: DownloadManager
        get() = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    private companion object {
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}
