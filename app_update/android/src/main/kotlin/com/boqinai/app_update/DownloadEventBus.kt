package com.boqinai.app_update

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

object DownloadEventBus : EventChannel.StreamHandler {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    @Volatile
    private var latest: Map<String, Any>? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        latest?.let(events::success)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun publish(event: Map<String, Any>) {
        latest = event
        mainHandler.post { sink?.success(event) }
    }

    fun clear() {
        latest = null
    }
}
