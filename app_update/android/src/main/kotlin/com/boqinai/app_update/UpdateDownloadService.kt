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
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class UpdateDownloadService : Service() {
    private val executor = Executors.newCachedThreadPool()
    private val cancellations = ConcurrentHashMap<Long, AtomicBoolean>()

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notifications.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "应用更新", NotificationManager.IMPORTANCE_LOW),
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_DOWNLOAD -> begin(intent)
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

    private fun begin(intent: Intent) {
        val id = intent.getLongExtra(EXTRA_ID, -1)
        val source = intent.getStringExtra(EXTRA_URL) ?: return
        val version = intent.getStringExtra(EXTRA_VERSION).orEmpty()
        val path = intent.getStringExtra(EXTRA_PATH) ?: return
        val wifiOnly = intent.getBooleanExtra(EXTRA_WIFI_ONLY, false)
        val cancelled = AtomicBoolean(false)
        cancellations[id] = cancelled
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
        executor.execute { download(id, source, version, File(path), wifiOnly, cancelled) }
    }

    private fun download(
        id: Long,
        source: String,
        version: String,
        destination: File,
        wifiOnly: Boolean,
        cancelled: AtomicBoolean,
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
                connect()
            }
            check(connection.responseCode in 200..299) { "HTTP ${connection.responseCode}" }
            val total = connection.contentLengthLong.coerceAtLeast(0)
            var downloaded = 0L
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
            if (destination.exists()) destination.delete()
            if (!partial.renameTo(destination)) {
                partial.copyTo(destination, overwrite = true)
                partial.delete()
            }
            save(id, STATUS_SUCCESSFUL, downloaded, total)
            show(id, buildNotification(version, downloaded, total, "下载完成 100%", false))
        } catch (_: Exception) {
            partial.delete()
            if (cancelled.get()) {
                clear(id)
                notifications.cancel(notificationId(id))
            } else {
                save(id, STATUS_FAILED, 0, 0)
                show(id, buildNotification(version, 0, 0, "下载失败", false))
            }
        } finally {
            connection?.disconnect()
            cancellations.remove(id)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_DETACH)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(false)
            }
            stopSelf()
        }
    }

    private fun buildNotification(
        version: String,
        downloaded: Long,
        total: Long,
        text: String,
        indeterminate: Boolean,
    ): Notification {
        val active = text.startsWith("正在") || text.startsWith("等待") || text.startsWith("准备")
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(if (active) android.R.drawable.stat_sys_download else android.R.drawable.stat_sys_download_done)
            .setContentTitle("${applicationInfo.loadLabel(packageManager)} 更新 v$version")
            .setContentText(text)
            .setOnlyAlertOnce(true)
            .setOngoing(active)
            .setProgress(
                if (total > 0) 100 else 0,
                if (total > 0) percentage(downloaded, total) else 0,
                indeterminate,
            )
            .setContentIntent(launchIntent())
            .build()
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

    private fun hasWifi(): Boolean {
        val manager = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
        val network = manager.activeNetwork ?: return false
        return manager.getNetworkCapabilities(network)
            ?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
    }

    private fun cancelInternal(id: Long) {
        cancellations[id]?.set(true)
        clear(id)
        notifications.cancel(notificationId(id))
    }

    private fun show(id: Long, notification: Notification) =
        notifications.notify(notificationId(id), notification)

    private val notifications: NotificationManager
        get() = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

    private fun save(id: Long, status: Int, downloaded: Long, total: Long) {
        preferences.edit()
            .putBoolean("$id.exists", true)
            .putInt("$id.status", status)
            .putLong("$id.downloaded", downloaded)
            .putLong("$id.total", total)
            .apply()
    }

    private fun clear(id: Long) {
        preferences.edit().remove("$id.exists").remove("$id.status")
            .remove("$id.downloaded").remove("$id.total").apply()
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
        private const val CHANNEL_ID = "app_update_downloads"
        private const val PREFERENCES = "app_update_downloads"
        private const val STATUS_PENDING = 1
        private const val STATUS_RUNNING = 2
        private const val STATUS_SUCCESSFUL = 8
        private const val STATUS_FAILED = 16
        private val nextId = AtomicLong(System.currentTimeMillis())

        fun enqueue(
            context: Context,
            url: String,
            version: String,
            destination: File,
            wifiOnly: Boolean,
        ): Long {
            val id = nextId.incrementAndGet()
            ContextCompat.startForegroundService(
                context,
                Intent(context, UpdateDownloadService::class.java).apply {
                    action = ACTION_DOWNLOAD
                    putExtra(EXTRA_ID, id)
                    putExtra(EXTRA_URL, url)
                    putExtra(EXTRA_VERSION, version)
                    putExtra(EXTRA_PATH, destination.absolutePath)
                    putExtra(EXTRA_WIFI_ONLY, wifiOnly)
                },
            )
            return id
        }

        fun progress(context: Context, id: Long): Map<String, Any>? {
            val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            if (!preferences.getBoolean("$id.exists", false)) return null
            return mapOf(
                "status" to preferences.getInt("$id.status", STATUS_PENDING),
                "bytesDownloaded" to preferences.getLong("$id.downloaded", 0),
                "totalBytes" to preferences.getLong("$id.total", 0),
            )
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
