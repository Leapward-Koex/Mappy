package com.leapwardkoex.mappy

import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

internal class WatchAppMessageBridge(
    private val uuid: UUID,
    private val transport: PebbleTransport,
    private val eventSink: (Map<String, Any?>) -> Unit = {},
    private val inFlightTimeoutMillis: Long = DEFAULT_IN_FLIGHT_TIMEOUT_MILLIS,
    private val dispatcher: (Map<*, *>) -> List<Map<String, Any?>>
) : PebbleTransportReceiver {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(4))
    private val lock = Any()
    private val queue = ArrayDeque<QueuedMessage>()
    private var inFlight: QueuedMessage? = null
    private var nextTransactionId = 1
    private var started = false
    private var watchReady = false
    private var watchLaunchPending = false
    private var timeoutJob: Job? = null
    private var pumpWakeJob: Job? = null

    fun start() {
        synchronized(lock) {
            if (started) {
                return
            }
            started = true
        }
        transport.register(uuid, this)
        emitTransportChanged("registered")
        pump()
    }

    fun stop() {
        synchronized(lock) {
            started = false
            watchReady = false
            queue.clear()
            inFlight = null
            timeoutJob?.cancel()
            timeoutJob = null
            pumpWakeJob?.cancel()
            pumpWakeJob = null
        }
        transport.unregister()
        scope.cancel()
        emitTransportChanged("stopped")
    }

    fun startWatchApp() {
        synchronized(lock) {
            watchLaunchPending = true
        }
        emitTransportChanged("launchRequested")
        transport.startWatchApp(uuid)
    }

    fun enqueue(fields: Map<*, *>) {
        val normalized = normalize(fields)
        if (normalized.isEmpty()) {
            return
        }
        val dropped = synchronized(lock) {
            enqueueLocked(QueuedMessage(fields = normalized, priority = priorityFor(normalized)))
        }
        dropped.forEach { emitQueueDrop(it.message, it.reason) }
        emitTransportChanged("queued")
        pump()
    }

    fun enqueueAll(messages: List<Map<String, Any?>>) {
        if (messages.isEmpty()) {
            return
        }
        val dropped = mutableListOf<DroppedMessage>()
        synchronized(lock) {
            if (messages.any { isRouteResetMessage(it) }) {
                queue.removeAll { it.isRouteResponse }
            }
            val hasMapSettings = messages.any { intValue(it[KEY_CMD]) == CMD_MAP_SETTINGS }
            if (hasMapSettings) {
                dropped.addAll(dropQueuedTilesLocked(REASON_MAP_SETTINGS_CHANGED))
            }
            messages.forEach { fields ->
                if (fields.isNotEmpty()) {
                    val queuedMessage = QueuedMessage(fields = fields, priority = priorityFor(fields))
                    if (hasMapSettings && queuedMessage.command == CMD_TILE) {
                        dropped.add(DroppedMessage(queuedMessage, REASON_MAP_SETTINGS_CHANGED))
                    } else {
                        dropped.addAll(enqueueLocked(queuedMessage))
                    }
                }
            }
        }
        dropped.forEach { emitQueueDrop(it.message, it.reason) }
        emitTransportChanged("queued")
        pump()
    }

    fun status(): Map<String, Any?> {
        val snapshot = synchronized(lock) {
            mapOf(
                "registered" to started,
                "watchReady" to watchReady,
                "queueLength" to queue.size,
                "inFlight" to (inFlight != null),
                "watchLaunchPending" to watchLaunchPending
            )
        }
        return snapshot +
            ("watchConnected" to transport.isWatchConnected()) +
            ("watchAppActive" to transport.isWatchAppActive(uuid))
    }

    override fun onWatchData(transactionId: Int, fields: Map<String, Any?>) {
        val command = intValue(fields[KEY_CMD])
        val protocolMatches = command != CMD_INIT ||
            intValue(fields[KEY_PROTOCOL_VERSION]) == WATCH_PROTOCOL_VERSION
        synchronized(lock) {
            watchReady = protocolMatches
            watchLaunchPending = false
        }
        transport.sendAck(transactionId)
        eventSink(
            mapOf(
                "event" to "watchCommand",
                "transactionId" to transactionId,
                "command" to command,
                KEY_REQUEST_ID to fields[KEY_REQUEST_ID],
                KEY_PROTOCOL_VERSION to fields[KEY_PROTOCOL_VERSION],
                KEY_TOTAL_BYTES to fields[KEY_TOTAL_BYTES],
                KEY_WORLD_X to fields[KEY_WORLD_X],
                KEY_WORLD_Y to fields[KEY_WORLD_Y],
                KEY_TILE_ZOOM to fields[KEY_TILE_ZOOM],
                KEY_BUTTON_ID to fields[KEY_BUTTON_ID],
                KEY_CHUNK_OFFSET to fields[KEY_CHUNK_OFFSET],
                KEY_CHUNK_INDEX to fields[KEY_CHUNK_INDEX],
                KEY_INSTRUCTION to fields[KEY_INSTRUCTION]
            )
        )
        scope.launch {
            val responses = try {
                dispatcher(fields)
            } catch (_: Exception) {
                emptyList()
            }
            enqueueAll(responses)
        }
        emitTransportChanged("watchData")
        pump()
    }

    override fun onWatchAck(transactionId: Int) {
        val completed = synchronized(lock) {
            val current = inFlight
            if (current?.transactionId == transactionId) {
                inFlight = null
                timeoutJob?.cancel()
                timeoutJob = null
                current
            } else {
                null
            }
        }
        if (completed != null) {
            emitSendResult("ack", completed, transactionId)
            pump()
        }
    }

    override fun onWatchNack(transactionId: Int) {
        handleSendFailure(transactionId, "nack")
    }

    override fun onWatchConnected() {
        emitTransportChanged("connected")
        pump()
    }

    override fun onWatchDisconnected() {
        val expired = synchronized(lock) {
            watchReady = false
            watchLaunchPending = false
            timeoutJob?.cancel()
            timeoutJob = null
            expireInFlightLocked(result = "disconnect")
        }
        emitFailureOutcome(expired)
        emitTransportChanged("disconnected")
    }

    override fun onWatchLaunchResult(success: Boolean) {
        synchronized(lock) {
            if (!success) watchLaunchPending = false
        }
        eventSink(
            mapOf(
                "event" to "watchLaunchResult",
                "success" to success,
                "status" to status()
            )
        )
        emitTransportChanged(if (success) "launchAccepted" else "launchFailed")
    }

    private fun enqueueLocked(message: QueuedMessage): List<DroppedMessage> {
        val dropped = mutableListOf<DroppedMessage>()
        when (message.command) {
            CMD_GPS -> queue.removeAll { it.command == CMD_GPS }
            CMD_TILE -> dropped.addAll(dropMatchingTilesLocked(REASON_SUPERSEDED_TILE) {
                it.requestKey != null && it.requestKey == message.requestKey
            })
            CMD_MAP_SETTINGS -> dropped.addAll(dropQueuedTilesLocked(REASON_MAP_SETTINGS_CHANGED))
            CMD_ROUTE_CLEAR -> queue.removeAll { it.isRouteResponse }
            CMD_ROUTE_POINTS -> queue.removeAll { it.isRouteResponse }
        }
        queue.add(message)
        dropped.addAll(trimQueueLocked())
        return dropped
    }

    private fun trimQueueLocked(): List<DroppedMessage> {
        val dropped = mutableListOf<DroppedMessage>()
        while (queue.size > MAX_QUEUE_LENGTH) {
            val oldestTileIndex = queue.indexOfFirst { it.command == CMD_TILE }
            val removedIndex = if (oldestTileIndex >= 0) {
                oldestTileIndex
            } else {
                val lowestPriority = queue.maxOf { it.priority }
                queue.indexOfFirst { it.priority == lowestPriority }
            }
            val removed = queue.removeAt(removedIndex)
            dropped.add(DroppedMessage(removed, REASON_QUEUE_OVERFLOW))
        }
        return dropped
    }

    private fun dropQueuedTilesLocked(reason: String): List<DroppedMessage> {
        return dropMatchingTilesLocked(reason) { it.command == CMD_TILE }
    }

    private fun dropMatchingTilesLocked(
        reason: String,
        predicate: (QueuedMessage) -> Boolean
    ): List<DroppedMessage> {
        val dropped = mutableListOf<DroppedMessage>()
        val iterator = queue.iterator()
        while (iterator.hasNext()) {
            val message = iterator.next()
            if (predicate(message)) {
                iterator.remove()
                dropped.add(DroppedMessage(message, reason))
            }
        }
        return dropped
    }

    private fun pump() {
        val canPump = synchronized(lock) {
            started && inFlight == null && watchReady && queue.isNotEmpty()
        }
        if (!canPump || !transport.isWatchConnected()) {
            return
        }
        val next = synchronized(lock) {
            if (!started || inFlight != null || !watchReady) {
                return
            }
            val message = removeNextLocked()
            if (message == null) {
                schedulePumpWakeLocked()
                return
            }
            val withTransaction = message.copy(
                transactionId = nextTransactionId
            )
            nextTransactionId = (nextTransactionId + 1).let { if (it > 255) 1 else it }
            inFlight = withTransaction
            withTransaction
        }

        try {
            transport.send(uuid, next.transactionId, next.fields)
            emitTransportChanged("sent")
            scheduleInFlightTimeout(next)
        } catch (_: Exception) {
            onWatchNack(next.transactionId)
        }
    }

    private fun scheduleInFlightTimeout(message: QueuedMessage) {
        if (inFlightTimeoutMillis <= 0) {
            return
        }
        timeoutJob?.cancel()
        timeoutJob = scope.launch {
            delay(inFlightTimeoutMillis)
            val expired = synchronized(lock) {
                val current = inFlight
                if (current?.transactionId == message.transactionId &&
                    current.attempts == message.attempts
                ) {
                    expireInFlightLocked(result = "timeout")
                } else {
                    null
                }
            }
            emitFailureOutcome(expired)
            if (expired != null) {
                pump()
            }
        }
    }

    private fun handleSendFailure(transactionId: Int, result: String) {
        val expired = synchronized(lock) {
            val current = inFlight
            if (current?.transactionId == transactionId) {
                expireInFlightLocked(result = result)
            } else {
                null
            }
        }
        emitFailureOutcome(expired)
        if (expired != null) {
            pump()
        }
    }

    private fun expireInFlightLocked(result: String): SendFailureOutcome? {
        val current = inFlight ?: return null
        inFlight = null
        timeoutJob?.cancel()
        timeoutJob = null
        if (result == "disconnect") {
            val requeued = current.copy(transactionId = 0)
            queue.addFirst(requeued)
            return SendFailureOutcome(requeued, result, current.transactionId, terminal = false)
        }
        val nextAttempt = current.copy(
            transactionId = 0,
            attempts = current.attempts + 1,
            availableAtMillis = monotonicMillis() + retryDelayMillis(current.attempts + 1)
        )
        return if (nextAttempt.shouldRetry) {
            queue.addFirst(nextAttempt)
            SendFailureOutcome(nextAttempt, result, current.transactionId, terminal = false)
        } else {
            val terminalResult = if (nextAttempt.isDroppable) "drop" else "failed"
            SendFailureOutcome(nextAttempt, terminalResult, current.transactionId, terminal = true)
        }
    }

    private fun emitFailureOutcome(outcome: SendFailureOutcome?) {
        if (outcome == null) {
            return
        }
        emitSendResult(outcome.result, outcome.message, outcome.transactionId)
        if (outcome.terminal) {
            emitDeliveryFailure(outcome.result, outcome.message, outcome.transactionId)
            if (outcome.message.command == CMD_TILE) {
                emitQueueDrop(outcome.message, reason = outcome.result)
            }
        }
    }

    private fun removeNextLocked(): QueuedMessage? {
        if (queue.isEmpty()) {
            return null
        }
        val now = monotonicMillis()
        var bestIndex = -1
        var bestPriority = Int.MAX_VALUE
        queue.forEachIndexed { index, message ->
            if (message.availableAtMillis <= now && message.priority < bestPriority) {
                bestIndex = index
                bestPriority = message.priority
            }
        }
        return if (bestIndex >= 0) queue.removeAt(bestIndex) else null
    }

    private fun schedulePumpWakeLocked() {
        val nextAt = queue.minOfOrNull { it.availableAtMillis } ?: return
        val waitMillis = (nextAt - monotonicMillis()).coerceAtLeast(1L)
        pumpWakeJob?.cancel()
        pumpWakeJob = scope.launch {
            delay(waitMillis)
            pump()
        }
    }

    private fun normalize(fields: Map<*, *>): Map<String, Any?> =
        linkedMapOf<String, Any?>().apply {
            fields.forEach { (key, value) ->
                if (key != null) {
                    put(key.toString(), value)
                }
            }
        }

    private fun priorityFor(fields: Map<String, Any?>): Int =
        when (intValue(fields[KEY_CMD])) {
            CMD_ERROR_STATE -> if (isRouteError(fields)) PRIORITY_ROUTE else PRIORITY_CONTROL
            CMD_ROUTE_CLEAR,
            CMD_PHONE_READY,
            CMD_THEME,
            CMD_TRAVEL_MODE,
            CMD_UNITS,
            CMD_BACKLIGHT,
            CMD_DECLINATION,
            CMD_MAP_SETTINGS,
            CMD_MAP_ORIENTATION,
            CMD_TILE_ANIMATION -> PRIORITY_CONTROL
            CMD_GPS -> PRIORITY_GPS
            CMD_DESTINATIONS -> PRIORITY_DESTINATIONS
            CMD_ROUTE_POINTS,
            CMD_NAV_STEPS -> PRIORITY_ROUTE
            CMD_TILE -> PRIORITY_TILE
            else -> PRIORITY_LOW
        }

    private fun isRouteResetMessage(fields: Map<String, Any?>): Boolean =
        when (intValue(fields[KEY_CMD])) {
            CMD_ROUTE_CLEAR,
            CMD_ROUTE_POINTS -> true
            CMD_ERROR_STATE -> isRouteError(fields)
            else -> false
        }

    private fun isRouteError(fields: Map<String, Any?>): Boolean =
        when (intValue(fields[KEY_CHUNK_INDEX])) {
            CMD_ROUTE_REQUEST,
            CMD_ROUTE_CLEAR,
            CMD_NAV_STEPS -> true
            else -> false
        }

    private fun intValue(value: Any?): Int? =
        when (value) {
            is Int -> value
            is Long -> value.toInt()
            is Double -> if (value.isFinite()) value.toInt() else null
            is Float -> if (value.isFinite()) value.toInt() else null
            is Number -> value.toInt()
            else -> null
        }

    private fun emitTransportChanged(reason: String) {
        eventSink(
            mapOf(
                "event" to "transportChanged",
                "reason" to reason,
                "status" to status()
            )
        )
    }

    private fun emitSendResult(result: String, message: QueuedMessage, transactionId: Int) {
        eventSink(
            mapOf(
                "event" to "sendResult",
                "transactionId" to transactionId,
                "command" to message.command,
                "result" to result,
                "attempts" to message.attempts,
                "status" to status()
            ) + tileEventFields(message)
        )
    }

    private fun emitDeliveryFailure(result: String, message: QueuedMessage, transactionId: Int) {
        eventSink(
            mapOf(
                "event" to "deliveryFailure",
                "transactionId" to transactionId,
                "command" to message.command,
                "result" to result,
                "attempts" to message.attempts,
                "droppable" to message.isDroppable,
                KEY_REQUEST_ID to message.fields[KEY_REQUEST_ID],
                KEY_WORLD_X to message.fields[KEY_WORLD_X],
                KEY_WORLD_Y to message.fields[KEY_WORLD_Y],
                KEY_TILE_ZOOM to message.fields[KEY_TILE_ZOOM],
                "status" to status()
            ) + tileEventFields(message)
        )
    }

    private fun emitQueueDrop(message: QueuedMessage, reason: String = "queueOverflow") {
        if (message.command != CMD_TILE) {
            return
        }
        eventSink(
            mapOf(
                "event" to "tileDrop",
                "reason" to reason,
                "command" to message.command,
                KEY_WORLD_X to message.fields[KEY_WORLD_X],
                KEY_WORLD_Y to message.fields[KEY_WORLD_Y],
                KEY_TILE_ZOOM to message.fields[KEY_TILE_ZOOM],
                "status" to status()
            ) + tileEventFields(message)
        )
    }

    private fun tileEventFields(message: QueuedMessage): Map<String, Any?> {
        if (message.command != CMD_TILE) {
            return emptyMap()
        }
        return mapOf(
            KEY_WIDTH to message.fields[KEY_WIDTH],
            KEY_HEIGHT to message.fields[KEY_HEIGHT],
            KEY_TOTAL_BYTES to message.fields[KEY_TOTAL_BYTES],
            KEY_CHUNK_INDEX to message.fields[KEY_CHUNK_INDEX],
            KEY_CHUNK_OFFSET to message.fields[KEY_CHUNK_OFFSET],
            KEY_REQUEST_ID to message.fields[KEY_REQUEST_ID],
            "tileKey" to message.tileKey,
            "requestKey" to message.requestKey
        )
    }

    private data class QueuedMessage(
        val fields: Map<String, Any?>,
        val priority: Int,
        val attempts: Int = 0,
        val transactionId: Int = 0,
        val availableAtMillis: Long = 0L
    ) {
        val command: Int? = (fields[KEY_CMD] as? Number)?.toInt()
        val failedCommand: Int? = (fields[KEY_CHUNK_INDEX] as? Number)?.toInt()
        val isDroppable: Boolean = command == CMD_TILE
        val isRouteResponse: Boolean =
            command == CMD_ROUTE_POINTS ||
                command == CMD_NAV_STEPS ||
                command == CMD_ROUTE_CLEAR ||
                (command == CMD_ERROR_STATE &&
                    (failedCommand == CMD_ROUTE_REQUEST ||
                        failedCommand == CMD_ROUTE_CLEAR ||
                        failedCommand == CMD_NAV_STEPS))
        val tileKey: String? =
            if (command == CMD_TILE) {
                listOf(
                    fields[KEY_WORLD_X],
                    fields[KEY_WORLD_Y],
                    fields[KEY_TILE_ZOOM],
                    fields[KEY_WIDTH],
                    fields[KEY_HEIGHT],
                    fields[KEY_CHUNK_INDEX],
                    fields[KEY_CHUNK_OFFSET]
                ).joinToString(":")
            } else {
                null
            }
        val requestKey: String? =
            if (command == CMD_TILE) {
                listOf(
                    fields[KEY_WORLD_X],
                    fields[KEY_WORLD_Y],
                    fields[KEY_TILE_ZOOM]
                ).joinToString(":")
            } else {
                null
            }
        val maxAttempts: Int = when (command) {
            CMD_LOG_EVENT -> 1
            CMD_GPS -> 2
            else -> 3
        }
        val shouldRetry: Boolean = attempts < maxAttempts
    }

    private data class SendFailureOutcome(
        val message: QueuedMessage,
        val result: String,
        val transactionId: Int,
        val terminal: Boolean
    )

    private data class DroppedMessage(
        val message: QueuedMessage,
        val reason: String
    )

    private companion object {
        private const val MAX_QUEUE_LENGTH = 64
        private const val DEFAULT_IN_FLIGHT_TIMEOUT_MILLIS = 2_000L
        private const val PRIORITY_CONTROL = 0
        private const val PRIORITY_GPS = 1
        private const val PRIORITY_DESTINATIONS = 2
        private const val PRIORITY_ROUTE = 3
        private const val PRIORITY_TILE = 4
        private const val PRIORITY_LOW = 5
        private const val REASON_QUEUE_OVERFLOW = "queueOverflow"
        private const val REASON_MAP_SETTINGS_CHANGED = "mapSettingsChanged"
        private const val REASON_SUPERSEDED_TILE = "supersededTile"

        private fun monotonicMillis(): Long = System.nanoTime() / 1_000_000L

        private fun retryDelayMillis(attempts: Int): Long =
            if (attempts <= 1) 150L else 400L
    }
}
