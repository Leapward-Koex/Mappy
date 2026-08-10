package com.leapwardkoex.mappy

import android.content.Context
import android.util.Log
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

internal class MappyWatchRuntime private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(4))
    private val eventLock = Any()
    private val uiEventSinks = linkedSetOf<(Map<String, Any?>) -> Unit>()
    private val routeConfirmations = ConcurrentHashMap<Int, CompletableDeferred<String>>()
    private val activeJobs = AtomicInteger(0)
    @Volatile private var pendingLaunchRequestId: Int? = null

    val apiKeyStore = ApiKeyStore(appContext)
    val mapTilesProvider = GoogleMapTilesProvider(
        appContext,
        apiKeyStore,
        allowUnrestrictedDevelopmentKey = { isSeededDevelopmentApiKey() }
    )

    lateinit var bridge: WatchAppMessageBridge
        private set

    val dispatcher: MappyWatchCommandDispatcher

    init {
        mapTilesProvider.setMapTileSettings(loadMapTileSettings(appContext), clearCaches = false)
        seedDevelopmentApiKeyIfPresent()
        dispatcher = MappyWatchCommandDispatcher(
            context = appContext,
            apiKeyStore = apiKeyStore,
            mapTilesProvider = mapTilesProvider,
            scope = scope,
            enqueueLater = { messages -> if (::bridge.isInitialized) bridge.enqueueAll(messages) },
            eventSink = ::handleDispatcherEvent
        )
        bridge = WatchAppMessageBridge(
            uuid = WATCH_APP_UUID,
            transport = PebbleKit2Transport(appContext),
            dispatcher = dispatcher::dispatch,
            eventSink = ::handleBridgeEvent
        ).also { it.start() }
        WatchLocationStreamer.attach(
            appContext,
            bridge,
            onStatusChanged = { emitEvent(mapOf("event" to "locationStatusChanged")) },
            onLocationAccepted = { emitEvent(mapOf("event" to "locationFixUpdated")) },
            onStreamError = { text -> emitEvent(mapOf("event" to "locationStreamError", "detail" to text)) }
        )
    }

    fun attachUi(eventSink: (Map<String, Any?>) -> Unit) {
        synchronized(eventLock) { uiEventSinks.add(eventSink) }
        emitEvent(mapOf("event" to "runtimeAttached"))
    }

    fun detachUi(eventSink: (Map<String, Any?>) -> Unit) {
        synchronized(eventLock) { uiEventSinks.remove(eventSink) }
        shutdownIfIdle()
    }

    fun startWatchApp() {
        emitEvent(mapOf("event" to "watchLaunchRequested"))
        bridge.startWatchApp()
    }

    fun status(): Map<String, Any?> = bridge.status() + mapOf(
        "foregroundServiceActive" to WatchSessionForegroundService.isActive,
        "foregroundServiceLastError" to WatchSessionForegroundService.lastStartError(),
        "protocolVersion" to WATCH_PROTOCOL_VERSION
    )

    fun enqueue(message: Map<*, *>) = bridge.enqueue(message)

    fun enqueueAll(messages: List<Map<String, Any?>>) = bridge.enqueueAll(messages)

    fun startNavigation(request: Map<*, *>, onResult: (Map<String, Any?>) -> Unit) {
        launchTracked {
            onResult(dispatchNavigation(dispatcher.startNavigation(request)))
        }
    }

    fun rerouteActiveRoute(onResult: (Map<String, Any?>) -> Unit) {
        launchTracked {
            onResult(dispatchNavigation(dispatcher.rerouteActiveRoute()))
        }
    }

    fun clearActiveRoute(): Map<String, Any?> {
        val requestId = dispatcher.activeRequestId() ?: 0
        dispatcher.clearActiveRoute()
        val messages = listOf(watchMessage(CMD_ROUTE_CLEAR, mapOf(KEY_REQUEST_ID to requestId)))
        bridge.enqueueAll(messages)
        return mapOf(
            "responses" to messages,
            "deliveryState" to "queued",
            "routeRequestId" to requestId,
            "detail" to "Route clear queued."
        )
    }

    fun <T> submit(block: () -> T, onResult: (Result<T>) -> Unit) {
        launchTracked { onResult(runCatching(block)) }
    }

    private fun launchTracked(block: suspend () -> Unit) {
        activeJobs.incrementAndGet()
        scope.launch {
            try {
                block()
            } finally {
                if (activeJobs.decrementAndGet() == 0) shutdownIfIdle()
            }
        }
    }

    private fun canShutdown(): Boolean {
        val bridgeStatus = bridge.status()
        return synchronized(eventLock) { uiEventSinks.isEmpty() } &&
            activeJobs.get() == 0 &&
            routeConfirmations.isEmpty() &&
            dispatcher.activeRequestId() == null &&
            !dispatcher.hasBackgroundWork() &&
            !MappyWatchSessionHub.isWatchAppActive(WATCH_APP_UUID) &&
            !WatchLocationStreamer.isRequested() &&
            (bridgeStatus["queueLength"] as? Number)?.toInt() == 0 &&
            bridgeStatus["inFlight"] != true
    }

    private fun shutdown() {
        WatchLocationStreamer.detachBridge(bridge)
        bridge.stop()
        routeConfirmations.values.forEach { it.cancel() }
        routeConfirmations.clear()
        scope.cancel()
    }

    private suspend fun dispatchNavigation(calculation: NativeRouteCalculation): Map<String, Any?> {
        if (!calculation.successful) {
            return mapOf(
                "responses" to calculation.messages,
                "deliveryState" to if (calculation.errorCategory == ERROR_PROTOCOL_MISMATCH) "protocolMismatch" else "deliveryFailed",
                "routeRequestId" to calculation.requestId,
                "detail" to calculation.detail
            )
        }

        val confirmation = CompletableDeferred<String>()
        routeConfirmations[calculation.requestId]?.cancel()
        routeConfirmations[calculation.requestId] = confirmation
        val readyBeforeSend = bridge.status()["watchReady"] == true
        bridge.enqueueAll(calculation.messages)
        emitEvent(mapOf("event" to "navigationQueued", KEY_REQUEST_ID to calculation.requestId))
        if (!readyBeforeSend) {
            pendingLaunchRequestId = calculation.requestId
            startWatchApp()
        }

        val outcome = withTimeoutOrNull(NAVIGATION_CONFIRMATION_TIMEOUT_MILLIS) { confirmation.await() }
        if (routeConfirmations[calculation.requestId] === confirmation) {
            routeConfirmations.remove(calculation.requestId)
        }
        if (pendingLaunchRequestId == calculation.requestId) pendingLaunchRequestId = null
        val state = outcome ?: "timedOut"
        val detail = when (state) {
            "applied" -> "Navigation confirmed on watch."
            "launchFailed" -> "Route ready, but the watch app could not be opened."
            "deliveryFailed" -> "Route ready, but delivery to the watch failed."
            "protocolMismatch" -> "Phone and watch must be updated together."
            else -> "Route ready on phone; watch did not confirm."
        }
        emitEvent(mapOf(
            "event" to when (state) {
                "applied" -> "navigationApplied"
                "launchFailed" -> "watchLaunchFailed"
                "deliveryFailed" -> "navigationDeliveryFailure"
                "protocolMismatch" -> "protocolMismatch"
                else -> "navigationDeliveryTimeout"
            },
            KEY_REQUEST_ID to calculation.requestId,
            "detail" to detail
        ))
        return mapOf(
            "responses" to calculation.messages,
            "deliveryState" to state,
            "routeRequestId" to calculation.requestId,
            "detail" to detail
        )
    }

    private fun handleBridgeEvent(event: Map<String, Any?>) {
        when (event["event"] as? String) {
            "sendResult" -> if (event["result"] == "ack") MappyWatchSessionHub.noteSuccessfulActivity(appContext)
            "watchCommand" -> {
                val command = (event["command"] as? Number)?.toInt()
                val requestId = (event[KEY_REQUEST_ID] as? Number)?.toInt()
                if (command == CMD_ROUTE_APPLIED && requestId != null) {
                    routeConfirmations.remove(requestId)?.complete("applied")
                    emitEvent(mapOf("event" to "navigationApplied", KEY_REQUEST_ID to requestId))
                }
                if (command == CMD_ROUTE_COMPLETE && requestId != null) {
                    dispatcher.clearActiveRoute(requestId)
                    emitEvent(mapOf("event" to "navigationCompleted", KEY_REQUEST_ID to requestId))
                }
            }
            "watchLaunchResult" -> if (event["success"] == false) {
                pendingLaunchRequestId?.let { requestId ->
                    routeConfirmations.remove(requestId)?.complete("launchFailed")
                }
            }
            "deliveryFailure" -> emitEvent(mapOf(
                "event" to "navigationDeliveryFailure",
                "command" to event["command"],
                KEY_REQUEST_ID to event[KEY_REQUEST_ID],
                "detail" to event["result"]
            )).also {
                (event[KEY_REQUEST_ID] as? Number)?.toInt()?.let { requestId ->
                    routeConfirmations.remove(requestId)?.complete("deliveryFailed")
                }
            }
        }
        emitEvent(event)
    }

    private fun handleDispatcherEvent(event: Map<String, Any?>) {
        if (event["event"] == "protocolMismatch") {
            Log.e(
                LOG_TAG,
                "Protocol mismatch: watch=${event["watchVersion"]} phone=${event["phoneVersion"]}."
            )
            routeConfirmations.entries.toList().forEach { (requestId, confirmation) ->
                if (routeConfirmations.remove(requestId, confirmation)) {
                    confirmation.complete("protocolMismatch")
                }
            }
        }
        emitEvent(event)
    }

    private fun emitEvent(event: Map<String, Any?>) {
        val payload = LinkedHashMap<String, Any?>().apply {
            putAll(event)
            putIfAbsent("timestampMillis", System.currentTimeMillis())
        }
        synchronized(eventLock) { uiEventSinks.toList() }.forEach { sink ->
            runCatching { sink(payload) }
        }
    }

    private fun seedDevelopmentApiKeyIfPresent() {
        val developmentKey = BuildConfig.MAPPY_DEV_GOOGLE_API_KEY.trim()
        if (developmentKey.isEmpty()) return
        val currentKey = runCatching { apiKeyStore.getPlaintextKey() }.getOrNull()
        val seeded = apiKeyStore.hasSeededDevelopmentKeyMarker()
        if (currentKey == null || (seeded && currentKey != developmentKey)) {
            mapTilesProvider.clearProviderSessions()
            apiKeyStore.storeSeededDevelopmentApiKey(developmentKey)
        }
    }

    private fun isSeededDevelopmentApiKey(): Boolean {
        val developmentKey = BuildConfig.MAPPY_DEV_GOOGLE_API_KEY.trim()
        return developmentKey.isNotEmpty() && runCatching {
            apiKeyStore.isSeededDevelopmentApiKey(developmentKey)
        }.getOrDefault(false)
    }

    companion object {
        private const val LOG_TAG = "MappyWatchRuntime"
        private const val NAVIGATION_CONFIRMATION_TIMEOUT_MILLIS = 15_000L
        @Volatile private var instance: MappyWatchRuntime? = null

        fun get(context: Context): MappyWatchRuntime = instance ?: synchronized(this) {
            instance ?: MappyWatchRuntime(context.applicationContext).also { instance = it }
        }

        fun existing(): MappyWatchRuntime? = instance

        fun shutdownIfIdle() {
            synchronized(this) {
                val current = instance ?: return
                if (!current.canShutdown()) return
                instance = null
                current.shutdown()
            }
        }
    }
}
