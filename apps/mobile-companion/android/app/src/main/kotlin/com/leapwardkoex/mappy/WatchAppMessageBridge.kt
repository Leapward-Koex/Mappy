package com.leapwardkoex.mappy

import java.util.UUID

internal class WatchAppMessageBridge(
    private val uuid: UUID,
    private val transport: PebbleTransport,
    private val eventSink: (Map<String, Any?>) -> Unit = {},
    private val inFlightTimeoutMillis: Long = DEFAULT_IN_FLIGHT_TIMEOUT_MILLIS,
    private val dispatcher: (Map<*, *>) -> List<Map<String, Any?>>
) : PebbleTransportReceiver {
    private val lock = Any()
    private val queue = ArrayDeque<QueuedMessage>()
    private var inFlight: QueuedMessage? = null
    private var nextTransactionId = 1
    private var started = false
    private var watchReady = false

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
        }
        transport.unregister()
        emitTransportChanged("stopped")
    }

    fun startWatchApp() {
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
                "inFlight" to (inFlight != null)
            )
        }
        return snapshot +
            ("watchConnected" to transport.isWatchConnected()) +
            ("watchAppActive" to transport.isWatchAppActive(uuid))
    }

    override fun onWatchData(transactionId: Int, fields: Map<String, Any?>) {
        synchronized(lock) {
            val command = intValue(fields[KEY_CMD])
            if (command == CMD_INIT) {
                watchReady = true
            }
        }
        transport.sendAck(transactionId)
        eventSink(
            mapOf(
                "event" to "watchCommand",
                "transactionId" to transactionId,
                "command" to intValue(fields[KEY_CMD]),
                KEY_WORLD_X to fields[KEY_WORLD_X],
                KEY_WORLD_Y to fields[KEY_WORLD_Y],
                KEY_TILE_ZOOM to fields[KEY_TILE_ZOOM]
            )
        )
        Thread {
            val responses = try {
                dispatcher(fields)
            } catch (_: Exception) {
                emptyList()
            }
            enqueueAll(responses)
        }.start()
        emitTransportChanged("watchData")
        pump()
    }

    override fun onWatchAck(transactionId: Int) {
        val completed = synchronized(lock) {
            val current = inFlight
            if (current?.transactionId == transactionId) {
                inFlight = null
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
            expireInFlightLocked(result = "disconnect")
        }
        emitFailureOutcome(expired)
        emitTransportChanged("disconnected")
    }

    private fun enqueueLocked(message: QueuedMessage): List<DroppedMessage> {
        val dropped = mutableListOf<DroppedMessage>()
        when (message.command) {
            CMD_GPS -> queue.removeAll { it.command == CMD_GPS }
            CMD_TILE -> dropped.addAll(dropMatchingTilesLocked(REASON_SUPERSEDED_TILE) {
                it.tileKey != null && it.tileKey == message.tileKey
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
            val tileIndex = queue.indexOfLast { it.command == CMD_TILE }
            val removed = if (tileIndex >= 0) {
                queue.removeAt(tileIndex)
            } else {
                queue.removeLast()
            }
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
            val message = removeNextLocked() ?: return
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
        Thread {
            try {
                Thread.sleep(inFlightTimeoutMillis)
            } catch (_: InterruptedException) {
                return@Thread
            }
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
        }.apply {
            name = "mappy-watch-message-timeout-${message.transactionId}"
            isDaemon = true
            start()
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
        if (result == "disconnect") {
            val requeued = current.copy(transactionId = 0)
            queue.addFirst(requeued)
            return SendFailureOutcome(requeued, result, current.transactionId, terminal = false)
        }
        val nextAttempt = current.copy(
            transactionId = 0,
            attempts = current.attempts + 1
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
        var bestIndex = 0
        var bestPriority = queue.first().priority
        queue.forEachIndexed { index, message ->
            if (message.priority < bestPriority) {
                bestIndex = index
                bestPriority = message.priority
            }
        }
        return queue.removeAt(bestIndex)
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
            "tileKey" to message.tileKey,
            "requestKey" to message.requestKey
        )
    }

    private data class QueuedMessage(
        val fields: Map<String, Any?>,
        val priority: Int,
        val attempts: Int = 0,
        val transactionId: Int = 0
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
        val shouldRetry: Boolean = isDroppable && attempts < MAX_SEND_ATTEMPTS
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
        private const val MAX_SEND_ATTEMPTS = 3
        private const val DEFAULT_IN_FLIGHT_TIMEOUT_MILLIS = 30_000L
        private const val PRIORITY_CONTROL = 0
        private const val PRIORITY_GPS = 1
        private const val PRIORITY_DESTINATIONS = 2
        private const val PRIORITY_ROUTE = 3
        private const val PRIORITY_TILE = 4
        private const val PRIORITY_LOW = 5
        private const val REASON_QUEUE_OVERFLOW = "queueOverflow"
        private const val REASON_MAP_SETTINGS_CHANGED = "mapSettingsChanged"
        private const val REASON_SUPERSEDED_TILE = "supersededTile"
    }
}
