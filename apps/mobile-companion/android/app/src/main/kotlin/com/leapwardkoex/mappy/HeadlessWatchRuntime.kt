package com.leapwardkoex.mappy

import android.content.Context

internal object HeadlessWatchRuntime {
    private val lock = Any()
    private var bridge: WatchAppMessageBridge? = null

    fun startIfNeeded(context: Context) {
        if (MappyWatchSessionHub.hasReceiver()) {
            return
        }
        synchronized(lock) {
            if (bridge != null || MappyWatchSessionHub.hasReceiver()) {
                return
            }
            bridge = WatchAppMessageBridge(
                uuid = MappyWatchSessionHub.watchAppUuid,
                transport = PebbleKit2Transport(context.applicationContext),
                dispatcher = { message -> dispatchHeadlessMessage(context.applicationContext, message) },
                eventSink = { event -> handleHeadlessEvent(context.applicationContext, event) }
            ).also {
                it.start()
                WatchLocationStreamer.attach(
                    context.applicationContext,
                    it,
                    onStatusChanged = {
                        WatchSessionForegroundService.noteActivity(context.applicationContext)
                    }
                )
            }
        }
    }

    fun stopIfRunning() {
        synchronized(lock) {
            WatchLocationStreamer.detachBridge(bridge)
            bridge?.stop()
            bridge = null
        }
    }

    private fun handleHeadlessEvent(context: Context, event: Map<String, Any?>) {
        when (event["event"] as? String) {
            "watchCommand",
            "sendResult",
            "transportChanged" -> WatchSessionForegroundService.noteActivity(context)
        }
    }

    private fun dispatchHeadlessMessage(context: Context, message: Map<*, *>): List<Map<String, Any?>> {
        WatchSessionForegroundService.noteActivity(context)
        return when ((message[KEY_CMD] as? Number)?.toInt()) {
            CMD_INIT -> {
                WatchLocationStreamer.request(context)
                listOf(headlessStatusMessage(context))
            }
            else -> listOf(
                errorMessage(
                    category = ERROR_ROUTE_PROVIDER,
                    failedCommand = (message[KEY_CMD] as? Number)?.toInt() ?: 0,
                    text = "Open phone app to finish setup."
                )
            )
        }
    }

    private fun headlessStatusMessage(context: Context): Map<String, Any?> {
        val hasLocation = hasAnyLocationPermission(context)
        val hasBackgroundLocation = WatchLocationStreamer.hasBackgroundLocation(context)
        val category = if (hasLocation && hasBackgroundLocation) ERROR_MISSING_KEY else ERROR_LOCATION_UNAVAILABLE
        val text = WatchSessionForegroundService.lastStartError()
            ?: if (category == ERROR_LOCATION_UNAVAILABLE) {
                if (hasLocation) {
                    "Open phone app to allow all-the-time location."
                } else {
                    "Open phone app to grant location."
                }
            } else {
                "Open phone app to finish setup."
            }
        return errorMessage(category = category, failedCommand = CMD_INIT, text = text)
    }

    private fun hasAnyLocationPermission(context: Context): Boolean =
        context.checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
            android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun errorMessage(
        category: Int,
        failedCommand: Int,
        text: String
    ): Map<String, Any?> =
        watchMessage(
            CMD_ERROR_STATE,
            linkedMapOf(
                KEY_BUTTON_ID to category,
                KEY_CHUNK_INDEX to failedCommand,
                KEY_CHUNK_OFFSET to 0,
                KEY_INSTRUCTION to text.take(MAX_WATCH_TEXT_CHARS)
            )
        )

    private const val MAX_WATCH_TEXT_CHARS = 47
}
