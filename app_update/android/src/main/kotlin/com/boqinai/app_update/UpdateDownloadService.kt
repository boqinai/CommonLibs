package com.boqinai.app_update

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class UpdateDownloadService : Service() {
    class DownloadInProgressException : IllegalStateException("Another update download is already active")

    private val executor = Executors.newSingleThreadExecutor()
    private val cancellations = ConcurrentHashMap<Long, AtomicBoolean>()
    private val startIds = ConcurrentHashMap<Long, Int>()
    private val versions = ConcurrentHashMap<Long, String>()
    private val timedOut = ConcurrentHashMap.newKeySet<Long>()

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "应用更新",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "应用更新下载进度"
                setSound(null, null)
                enableVibration(false)
            }
            notifications.createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DOWNLOAD -> begin(intent, startId)
            ACTION_CANCEL -> cancelInternal(intent.getLongExtra(EXTRA_ID, -1))
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        cancellations.values.forEach { it.set(true) }
        executor.shutdownNow()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.VANILLA_ICE_CREAM) return
        val id = startIds.entries.firstOrNull { it.value == startId }?.key ?: return
        timedOut.add(id)
        cancellations[id]?.set(true)
        val current = states[id]
        val downloaded = current?.get("bytesDownloaded") as? Long ?: 0L
        val total = current?.get("totalBytes") as? Long ?: 0L
        save(
            id,
            STATUS_FAILED,
            downloaded,
            total,
            ERROR_DATA_SYNC_TIMEOUT,
            "Android stopped the dataSync foreground service after its time limit",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
        show(id, buildNotification(versions[id].orEmpty(), downloaded, total, "下载超时，请重试", false))
        stopSelf(startId)
    }

    private fun begin(intent: Intent, startId: Int) {
        val id = intent.getLongExtra(EXTRA_ID, -1)
        val source = intent.getStringExtra(EXTRA_URL) ?: return
        val version = intent.getStringExtra(EXTRA_VERSION).orEmpty()
        val path = intent.getStringExtra(EXTRA_PATH) ?: return
        val wifiOnly = intent.getBooleanExtra(EXTRA_WIFI_ONLY, false)
        val expectedSha256 = intent.getStringExtra(EXTRA_SHA256)
        val expectedSize = intent.getLongExtra(EXTRA_SIZE, -1).takeIf { it >= 0 }
        val cancelled = AtomicBoolean(false)
        cancellations[id] = cancelled
        startIds[id] = startId
        versions[id] = version
        save(id, STATUS_PENDING, 0, 0)
        val initialNotification = buildNotification(version, 0, 0, "准备下载…", true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                notificationId(id),
                initialNotification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(notificationId(id), initialNotification)
        }
        executor.execute {
            download(
                id,
                source,
                version,
                File(path),
                wifiOnly,
                cancelled,
                expectedSha256,
                expectedSize,
            )
        }
    }

    private fun download(
        id: Long,
        source: String,
        version: String,
        destination: File,
        wifiOnly: Boolean,
        cancelled: AtomicBoolean,
        expectedSha256: String?,
        expectedSize: Long?,
    ) {
        val partial = File(destination.absolutePath + ".part")
        var connection: HttpURLConnection? = null
        try {
            while (wifiOnly && !hasWifi() && !cancelled.get()) {
                show(id, buildNotification(version, 0, 0, "等待 Wi-Fi…", true))
                Thread.sleep(2_000)
            }
            check(!cancelled.get()) { "cancelled" }
            destination.parentFile?.mkdirs()
            partial.delete()
            connection = (URL(source).openConnection() as HttpURLConnection).apply {
                connectTimeout = 15_000
                readTimeout = 30_000
                instanceFollowRedirects = true
                setRequestProperty("Accept-Encoding", "identity")
                connect()
            }
            check(connection.responseCode in 200..299) { "HTTP ${connection.responseCode}" }
            val total = (if (connection.contentLengthLong > 0) connection.contentLengthLong else (expectedSize ?: 0L)).coerceAtLeast(0)
            if (expectedSize != null && total > 0) {
                check(total == expectedSize) { "APK size mismatch" }
            }
            var downloaded = 0L
            val expectedHash = expectedSha256?.takeIf { it.isNotBlank() }
            val digest = expectedHash?.let { MessageDigest.getInstance("SHA-256") }
            var lastPublishedAt = 0L
            var lastPercent = -1
            connection.inputStream.use { input ->
                FileOutputStream(partial).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        check(!cancelled.get()) { "cancelled" }
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        digest?.update(buffer, 0, count)
                        downloaded += count
                        val percent = percentage(downloaded, total)
                        val now = System.currentTimeMillis()
                        if (percent != lastPercent || now - lastPublishedAt >= 500) {
                            save(id, STATUS_RUNNING, downloaded, total)
                            show(id, buildNotification(
                                version,
                                downloaded,
                                total,
                                if (total > 0) "正在下载… $percent%" else "正在下载…",
                                total <= 0,
                            ))
                            lastPercent = percent
                            lastPublishedAt = now
                        }
                    }
                    output.fd.sync()
                }
            }
            check(!cancelled.get()) { "cancelled" }
            if (expectedSize != null) {
                check(downloaded == expectedSize) { "APK size mismatch" }
            }
            if (digest != null && expectedHash != null) {
                val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
                check(actual.equals(expectedHash, ignoreCase = true)) { "APK checksum mismatch" }
            }
            val validation = ApkInstallValidator.validate(this, partial)
            if (!validation.valid) {
                partial.delete()
                save(
                    id,
                    STATUS_FAILED,
                    downloaded,
                    total,
                    validation.code ?: "invalid_apk",
                    validation.message ?: "APK validation failed",
                )
                show(id, buildNotification(version, downloaded, total, "安装包校验失败", false))
                return
            }
            if (destination.exists()) destination.delete()
            if (!partial.renameTo(destination)) {
                partial.copyTo(destination, overwrite = true)
                partial.delete()
            }
            save(id, STATUS_SUCCESSFUL, downloaded, total)
            show(id, buildNotification(version, downloaded, total, "下载完成 100%", false, destination))
        } catch (error: Exception) {
            partial.delete()
            if (timedOut.contains(id)) {
                // onTimeout has already persisted and published the terminal failure.
            } else if (cancelled.get()) {
                clear(id)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                notifications.cancel(notificationId(id))
            } else {
                save(id, STATUS_FAILED, 0, 0, "download_failed", error.message ?: "Download failed")
                show(id, buildNotification(version, 0, 0, "下载失败", false))
            }
        } finally {
            connection?.disconnect()
            val wasCancelled = cancelled.get()
            val wasTimedOut = timedOut.remove(id)
            cancellations.remove(id)
            startIds.remove(id)
            versions.remove(id)
            activeDownloadId.compareAndSet(id, NO_ACTIVE_DOWNLOAD)
            if (cancellations.isEmpty()) {
                if (wasCancelled && !wasTimedOut) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        stopForeground(STOP_FOREGROUND_REMOVE)
                    } else {
                        @Suppress("DEPRECATION")
                        stopForeground(true)
                    }
                    notifications.cancel(notificationId(id))
                } else {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                        stopForeground(STOP_FOREGROUND_DETACH)
                    } else {
                        @Suppress("DEPRECATION")
                        stopForeground(false)
                    }
                }
                stopSelf()
            }
        }
    }

    private fun buildNotification(
        version: String,
        downloaded: Long,
        total: Long,
        text: String,
        indeterminate: Boolean,
        destination: File? = null,
    ): Notification {
        val active = text.startsWith("正在") || text.startsWith("等待") || text.startsWith("准备")
        val contentIntent = if (destination != null && destination.isFile) {
            installIntent(destination) ?: launchIntent()
        } else {
            launchIntent()
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(notificationIcon(active))
            .setContentTitle("${applicationInfo.loadLabel(packageManager)} 更新 v$version")
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setOngoing(active)
            .setProgress(
                if (total > 0) 100 else 0,
                if (total > 0) percentage(downloaded, total) else 0,
                indeterminate,
            )
            .setContentIntent(contentIntent)
            .build()
    }

    private fun installIntent(apk: File): PendingIntent? {
        return try {
            if (!ApkInstallValidator.validate(this, apk).valid) return launchIntent()
            val uri = FileProvider.getUriForFile(
                this,
                "${packageName}.app_update.fileprovider",
                apk,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        } catch (_: Exception) {
            launchIntent()
        }
    }

    private fun launchIntent(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName) ?: return null
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun notificationIcon(active: Boolean): Int {
        val metadata = packageManager.getApplicationInfo(
            packageName,
            android.content.pm.PackageManager.GET_META_DATA,
        ).metaData
        val configured = metadata?.getInt(NOTIFICATION_ICON_METADATA, 0) ?: 0
        return configured.takeIf { it != 0 }
            ?: if (active) android.R.drawable.stat_sys_download
            else android.R.drawable.stat_sys_download_done
    }

    private fun hasWifi(): Boolean {
        val manager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = manager.activeNetwork ?: return false
        return manager.getNetworkCapabilities(network)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    private fun cancelInternal(id: Long) {
        cancellations[id]?.set(true)
        clear(id)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        notifications.cancel(notificationId(id))
    }

    private fun show(id: Long, notification: Notification) =
        notifications.notify(notificationId(id), notification)

    private val notifications: NotificationManager
        get() = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

    private fun save(
        id: Long,
        status: Int,
        downloaded: Long,
        total: Long,
        errorCode: String? = null,
        errorMessage: String? = null,
    ) {
        val event = mutableMapOf<String, Any>(
            "downloadId" to id,
            "status" to status,
            "bytesDownloaded" to downloaded,
            "totalBytes" to total,
        )
        errorCode?.let { event["errorCode"] = it }
        errorMessage?.let { event["errorMessage"] = it }
        states[id] = event
        if (status == STATUS_SUCCESSFUL || status == STATUS_FAILED) {
            preferences.edit()
                .putBoolean("$id.exists", true)
                .putInt("$id.status", status)
                .putLong("$id.downloaded", downloaded)
                .putLong("$id.total", total)
                .apply {
                    if (errorCode == null) remove("$id.errorCode") else putString("$id.errorCode", errorCode)
                    if (errorMessage == null) remove("$id.errorMessage") else putString("$id.errorMessage", errorMessage)
                }
                .apply()
        }
        DownloadEventBus.publish(event)
    }

    private fun clear(id: Long) {
        states.remove(id)
        preferences.edit().remove("$id.exists").remove("$id.status")
            .remove("$id.downloaded").remove("$id.total")
            .remove("$id.errorCode").remove("$id.errorMessage").apply()
    }

    private val preferences by lazy { getSharedPreferences(PREFERENCES, MODE_PRIVATE) }

    companion object {
        private const val ACTION_DOWNLOAD = "com.boqinai.app_update.DOWNLOAD"
        private const val ACTION_CANCEL = "com.boqinai.app_update.CANCEL"
        private const val EXTRA_ID = "id"
        private const val EXTRA_URL = "url"
        private const val EXTRA_VERSION = "version"
        private const val EXTRA_PATH = "path"
        private const val EXTRA_WIFI_ONLY = "wifiOnly"
        private const val EXTRA_SHA256 = "sha256"
        private const val EXTRA_SIZE = "size"
        private const val CHANNEL_ID = "app_update_downloads"
        private const val PREFERENCES = "app_update_downloads"
        private const val NOTIFICATION_ICON_METADATA = "com.boqinai.app_update.notification_icon"
        private const val STATUS_PENDING = 1
        private const val STATUS_RUNNING = 2
        private const val STATUS_SUCCESSFUL = 8
        private const val STATUS_FAILED = 16
        private const val ERROR_DATA_SYNC_TIMEOUT = "data_sync_timeout"
        private val nextId = AtomicLong(System.currentTimeMillis())
        private const val NO_ACTIVE_DOWNLOAD = -1L
        private val activeDownloadId = AtomicLong(NO_ACTIVE_DOWNLOAD)
        private val states = ConcurrentHashMap<Long, Map<String, Any>>()

        fun recordCompleted(
            context: Context,
            destination: File,
        ): Long {
            val id = nextId.incrementAndGet()
            states.clear()
            DownloadEventBus.clear()
            val total = destination.length()
            val event = mapOf<String, Any>(
                "downloadId" to id,
                "status" to STATUS_SUCCESSFUL,
                "bytesDownloaded" to total,
                "totalBytes" to total,
            )
            states[id] = event
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
                .edit()
                .clear()
                .putBoolean("$id.exists", true)
                .putInt("$id.status", STATUS_SUCCESSFUL)
                .putLong("$id.downloaded", total)
                .putLong("$id.total", total)
                .apply()
            DownloadEventBus.publish(event)
            return id
        }

        fun enqueue(
            context: Context,
            url: String,
            version: String,
            destination: File,
            wifiOnly: Boolean,
            expectedSha256: String?,
            expectedSize: Long?,
        ): Long {
            val id = nextId.incrementAndGet()
            if (!activeDownloadId.compareAndSet(NO_ACTIVE_DOWNLOAD, id)) {
                throw DownloadInProgressException()
            }
            states.clear()
            DownloadEventBus.clear()
            context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().clear().commit()
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, UpdateDownloadService::class.java).apply {
                        action = ACTION_DOWNLOAD
                        putExtra(EXTRA_ID, id)
                        putExtra(EXTRA_URL, url)
                        putExtra(EXTRA_VERSION, version)
                        putExtra(EXTRA_PATH, destination.absolutePath)
                        putExtra(EXTRA_WIFI_ONLY, wifiOnly)
                        putExtra(EXTRA_SHA256, expectedSha256)
                        if (expectedSize != null) putExtra(EXTRA_SIZE, expectedSize)
                    },
                )
            } catch (error: Exception) {
                activeDownloadId.compareAndSet(id, NO_ACTIVE_DOWNLOAD)
                throw error
            }
            return id
        }

        fun progress(context: Context, id: Long): Map<String, Any>? {
            states[id]?.let { return it }
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            if (!preferences.getBoolean("$id.exists", false)) return null
            return mutableMapOf<String, Any>(
                "status" to preferences.getInt("$id.status", STATUS_PENDING),
                "bytesDownloaded" to preferences.getLong("$id.downloaded", 0),
                "totalBytes" to preferences.getLong("$id.total", 0),
            ).apply {
                preferences.getString("$id.errorCode", null)?.let { put("errorCode", it) }
                preferences.getString("$id.errorMessage", null)?.let { put("errorMessage", it) }
            }
        }

        fun cancel(context: Context, id: Long): Boolean {
            if (progress(context, id) == null) return false
            context.startService(Intent(context, UpdateDownloadService::class.java).apply {
                action = ACTION_CANCEL
                putExtra(EXTRA_ID, id)
            })
            return true
        }

        private fun percentage(downloaded: Long, total: Long) =
            if (total <= 0) 0 else ((downloaded * 100) / total).coerceIn(0, 100).toInt()

        private fun notificationId(id: Long) = (id xor (id ushr 32)).toInt() and 0x7fffffff

    }
}
