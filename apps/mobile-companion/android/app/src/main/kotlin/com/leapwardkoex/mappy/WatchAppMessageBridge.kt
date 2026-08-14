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
    private val tileTransferPacingMillis: Long = DEFAULT_TILE_TRANSFER_PACING_MILLIS,
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
    private var activeTileTransferKey: String? = null
    private var nextTileTransferAtMillis = 0L
    private var tileWorkEpoch = 0L
    private val cancelledTileTransfers = mutableSetOf<String>()
    private val acknowledgedTileChunks = mutableMapOf<String, Int>()

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
            activeTileTransferKey = null
            nextTileTransferAtMillis = 0L
            cancelledTileTransfers.clear()
            acknowledgedTileChunks.clear()
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
        if (intValue(normalized[KEY_CMD]) == CMD_TILE) {
            enqueueAll(listOf(normalized))
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
        val dropped = synchronized(lock) { enqueueAllLocked(messages) }
        dropped.forEach { emitQueueDrop(it.message, it.reason) }
        emitTransportChanged("queued")
        pump()
    }

    private fun enqueueAllLocked(messages: List<Map<String, Any?>>): List<DroppedMessage> {
        val dropped = mutableListOf<DroppedMessage>()
        if (messages.any { isRouteResetMessage(it) }) {
            queue.removeAll { it.isRouteResponse }
        }
        val hasMapSettings = messages.any { intValue(it[KEY_CMD]) == CMD_MAP_SETTINGS }
        if (hasMapSettings) {
            dropped.addAll(cancelQueuedTileTransfersLocked(REASON_MAP_SETTINGS_CHANGED))
        }
        messages.filterNot { intValue(it[KEY_CMD]) == CMD_TILE }.forEach { fields ->
            if (fields.isNotEmpty()) {
                val queuedMessage = QueuedMessage(fields = fields, priority = priorityFor(fields))
                dropped.addAll(enqueueLocked(queuedMessage))
            }
        }
        val transferBatches = messages
            .filter { intValue(it[KEY_CMD]) == CMD_TILE }
            .groupBy(::tileBatchKey)
        transferBatches.values.forEach { fields ->
            if (hasMapSettings) {
                dropped.add(
                    DroppedMessage(
                        QueuedMessage(fields.first(), priorityFor(fields.first())),
                        REASON_MAP_SETTINGS_CHANGED
                    )
                )
                return@forEach
            }
            val transfer = buildTileTransfer(fields)
            if (transfer == null) {
                dropped.add(
                    DroppedMessage(
                        QueuedMessage(fields.first(), priorityFor(fields.first())),
                        REASON_INVALID_TILE_TRANSFER
                    )
                )
            } else {
                dropped.addAll(enqueueTileTransferLocked(transfer))
            }
        }
        dropped.addAll(trimQueueLocked())
        return dropped
    }

    fun status(): Map<String, Any?> {
        val snapshot = synchronized(lock) {
            mapOf(
                "registered" to started,
                "watchReady" to watchReady,
                "queueLength" to queue.size,
                "inFlight" to (inFlight != null),
                "watchLaunchPending" to watchLaunchPending,
                "tileWorkEpoch" to tileWorkEpoch
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
        val dropped = mutableListOf<DroppedMessage>()
        val dispatchEpoch = synchronized(lock) {
            watchReady = protocolMatches
            watchLaunchPending = false
            if (isZoomNotification(fields)) {
                tileWorkEpoch++
                dropped.addAll(cancelQueuedTileTransfersLocked(REASON_ZOOM_CHANGED))
            }
            tileWorkEpoch
        }
        transport.sendAck(transactionId)
        dropped.forEach { emitQueueDrop(it.message, it.reason) }
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
            var staleTileWork = false
            val responseDrops = synchronized(lock) {
                if (command == CMD_TILE_REQUEST && dispatchEpoch != tileWorkEpoch) {
                    staleTileWork = true
                    emptyList()
                } else {
                    enqueueAllLocked(responses)
                }
            }
            if (staleTileWork) {
                emitStaleTileWorkDrop(fields, responses.size)
            } else if (responses.isNotEmpty()) {
                responseDrops.forEach { emitQueueDrop(it.message, it.reason) }
                emitTransportChanged("queued")
                pump()
            }
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
                completeTileChunkLocked(current)
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
            CMD_MAP_SETTINGS -> dropped.addAll(cancelQueuedTileTransfersLocked(REASON_MAP_SETTINGS_CHANGED))
            CMD_ROUTE_CLEAR -> queue.removeAll { it.isRouteResponse }
            CMD_ROUTE_POINTS -> queue.removeAll { it.isRouteResponse }
        }
        queue.add(message)
        dropped.addAll(trimQueueLocked())
        return dropped
    }

    private fun enqueueTileTransferLocked(transfer: QueuedTileTransfer): List<DroppedMessage> {
        val dropped = mutableListOf<DroppedMessage>()
        val current = inFlight
        val existingTransfers = linkedMapOf<String, QueuedMessage>()
        queue.asSequence()
            .filter { it.command == CMD_TILE && it.requestKey == transfer.requestKey }
            .forEach { message ->
                message.transferKey?.let { existingTransfers.putIfAbsent(it, message) }
            }
        if (current?.command == CMD_TILE && current.requestKey == transfer.requestKey) {
            current.transferKey?.let { existingTransfers.putIfAbsent(it, current) }
        }

        val exactTransferExists = transfer.transferKey in existingTransfers ||
            transfer.transferKey in acknowledgedTileChunks
        if (exactTransferExists) {
            if (transfer.transferKey in cancelledTileTransfers) {
                return listOf(DroppedMessage(transfer.chunks.first(), REASON_STALE_TILE_REQUEST))
            }
            val acknowledgedCount = acknowledgedTileChunks[transfer.transferKey] ?: 0
            acknowledgedTileChunks.putIfAbsent(transfer.transferKey, acknowledgedCount)
            appendMissingTransferChunksLocked(transfer, acknowledgedCount, current)
            return dropped
        }

        existingTransfers.values.forEach { existing ->
            val existingRequestId = existing.requestId ?: return@forEach
            when (compareRequestIds(transfer.requestId, existingRequestId)) {
                -1 -> return listOf(DroppedMessage(transfer.chunks.first(), REASON_STALE_TILE_REQUEST))
                0 -> return listOf(DroppedMessage(transfer.chunks.first(), REASON_INVALID_TILE_TRANSFER))
            }
        }
        existingTransfers.keys.forEach { transferKey ->
            dropped.addAll(dropTileTransferLocked(transferKey, REASON_SUPERSEDED_TILE))
        }

        acknowledgedTileChunks[transfer.transferKey] = 0
        transfer.chunks.forEach(queue::add)
        return dropped
    }

    private fun appendMissingTransferChunksLocked(
        transfer: QueuedTileTransfer,
        acknowledgedCount: Int,
        current: QueuedMessage?
    ) {
        val existingChunkKeys = buildSet {
            queue.asSequence()
                .filter { it.transferKey == transfer.transferKey }
                .mapNotNullTo(this) { it.chunkKey }
            if (current?.transferKey == transfer.transferKey) {
                current.chunkKey?.let(::add)
            }
        }
        transfer.chunks.forEach { chunk ->
            val chunkIndex = chunk.tileChunkIndex ?: return@forEach
            if (chunkIndex >= acknowledgedCount && chunk.chunkKey !in existingChunkKeys) {
                queue.add(chunk)
            }
        }
    }

    private fun trimQueueLocked(): List<DroppedMessage> {
        val dropped = mutableListOf<DroppedMessage>()
        while (queue.size > MAX_QUEUE_LENGTH) {
            val oldestTileIndex = queue.indexOfFirst { it.command == CMD_TILE }
            if (oldestTileIndex >= 0) {
                val transferKey = queue[oldestTileIndex].transferKey
                if (transferKey != null) {
                    dropped.addAll(dropTileTransferLocked(transferKey, REASON_QUEUE_OVERFLOW))
                    continue
                }
            }
            val removedIndex = run {
                val lowestPriority = queue.maxOf { it.priority }
                queue.indexOfFirst { it.priority == lowestPriority }
            }
            val removed = queue.removeAt(removedIndex)
            dropped.add(DroppedMessage(removed, REASON_QUEUE_OVERFLOW))
        }
        return dropped
    }

    private fun cancelQueuedTileTransfersLocked(reason: String): List<DroppedMessage> {
        val dropped = dropMatchingTilesLocked(reason) { it.command == CMD_TILE }.toMutableList()
        val current = inFlight
        if (current?.command == CMD_TILE) {
            current.transferKey?.let { transferKey ->
                val newlyCancelled = cancelledTileTransfers.add(transferKey)
                if (newlyCancelled && dropped.none { it.message.transferKey == transferKey }) {
                    dropped.add(DroppedMessage(current, reason))
                }
                acknowledgedTileChunks.remove(transferKey)
                activeTileTransferKey = transferKey
            }
        } else {
            activeTileTransferKey = null
        }
        return dropped
    }

    private fun dropTileTransferLocked(transferKey: String, reason: String): List<DroppedMessage> {
        val dropped = dropMatchingTilesLocked(reason) { it.transferKey == transferKey }.toMutableList()
        val current = inFlight
        if (current?.transferKey == transferKey) {
            val newlyCancelled = cancelledTileTransfers.add(transferKey)
            if (newlyCancelled && dropped.isEmpty()) {
                dropped.add(DroppedMessage(current, reason))
            }
            activeTileTransferKey = transferKey
        } else if (activeTileTransferKey == transferKey) {
            activeTileTransferKey = null
        }
        acknowledgedTileChunks.remove(transferKey)
        return dropped
    }

    private fun dropMatchingTilesLocked(
        reason: String,
        predicate: (QueuedMessage) -> Boolean
    ): List<DroppedMessage> {
        val dropped = linkedMapOf<String, DroppedMessage>()
        val iterator = queue.iterator()
        while (iterator.hasNext()) {
            val message = iterator.next()
            if (predicate(message)) {
                iterator.remove()
                val transferKey = message.transferKey
                val logicalKey = transferKey ?: "unkeyed:${dropped.size}"
                dropped.putIfAbsent(logicalKey, DroppedMessage(message, reason))
                transferKey?.let(acknowledgedTileChunks::remove)
            }
        }
        return dropped.values.toList()
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
            scheduleInFlightTimeoutLocked(withTransaction)
            withTransaction
        }

        try {
            transport.send(uuid, next.transactionId, next.fields)
            emitTransportChanged("sent")
        } catch (_: Exception) {
            onWatchNack(next.transactionId)
        }
    }

    private fun scheduleInFlightTimeoutLocked(message: QueuedMessage) {
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
        val transferKey = current.transferKey
        val transferCancelled = transferKey != null && transferKey in cancelledTileTransfers
        if (transferCancelled) {
            dropTileTransferLocked(transferKey, REASON_CANCELLED_TILE_TRANSFER)
            cancelledTileTransfers.remove(transferKey)
            acknowledgedTileChunks.remove(transferKey)
            activeTileTransferKey = null
            nextTileTransferAtMillis = monotonicMillis() + tileTransferPacingMillis.coerceAtLeast(0L)
            return SendFailureOutcome(
                current.copy(transactionId = 0),
                "drop",
                current.transactionId,
                terminal = true
            )
        }
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
            if (transferKey != null) {
                dropTileTransferLocked(transferKey, terminalResult)
            }
            if (transferKey != null) {
                cancelledTileTransfers.remove(transferKey)
                acknowledgedTileChunks.remove(transferKey)
                activeTileTransferKey = null
                nextTileTransferAtMillis = monotonicMillis() + tileTransferPacingMillis.coerceAtLeast(0L)
            }
            SendFailureOutcome(
                nextAttempt,
                terminalResult,
                current.transactionId,
                terminal = true,
                tileDrop = current.takeIf { it.command == CMD_TILE }
                    ?.let { DroppedMessage(it, terminalResult) }
            )
        }
    }

    private fun emitFailureOutcome(outcome: SendFailureOutcome?) {
        if (outcome == null) {
            return
        }
        emitSendResult(outcome.result, outcome.message, outcome.transactionId)
        if (outcome.terminal) {
            emitDeliveryFailure(outcome.result, outcome.message, outcome.transactionId)
            outcome.tileDrop?.let { emitQueueDrop(it.message, it.reason) }
        }
    }

    private fun removeNextLocked(): QueuedMessage? {
        if (queue.isEmpty()) {
            return null
        }
        val now = monotonicMillis()
        var bestIndex = -1
        var bestPriority = Int.MAX_VALUE
        val firstActiveTileIndex = activeTileTransferKey?.let { transferKey ->
            queue.indexOfFirst { it.transferKey == transferKey }
        }
        queue.forEachIndexed { index, message ->
            val tileEligible = if (message.command != CMD_TILE) {
                true
            } else if (activeTileTransferKey != null) {
                index == firstActiveTileIndex
            } else {
                now >= nextTileTransferAtMillis
            }
            if (tileEligible &&
                message.availableAtMillis <= now &&
                message.priority < bestPriority
            ) {
                bestIndex = index
                bestPriority = message.priority
            }
        }
        if (bestIndex < 0) {
            return null
        }
        return queue.removeAt(bestIndex).also { message ->
            if (message.command == CMD_TILE && activeTileTransferKey == null) {
                activeTileTransferKey = message.transferKey
            }
        }
    }

    private fun schedulePumpWakeLocked() {
        val firstActiveTileIndex = activeTileTransferKey?.let { transferKey ->
            queue.indexOfFirst { it.transferKey == transferKey }
        }
        val nextAt = queue.mapIndexedNotNull { index, message ->
            if (message.command != CMD_TILE) {
                message.availableAtMillis
            } else if (activeTileTransferKey != null) {
                message.availableAtMillis.takeIf { index == firstActiveTileIndex }
            } else {
                maxOf(message.availableAtMillis, nextTileTransferAtMillis)
            }
        }.minOrNull() ?: return
        val waitMillis = (nextAt - monotonicMillis()).coerceAtLeast(1L)
        pumpWakeJob?.cancel()
        pumpWakeJob = scope.launch {
            delay(waitMillis)
            pump()
        }
    }

    private fun completeTileChunkLocked(message: QueuedMessage) {
        if (message.command != CMD_TILE) {
            return
        }
        val transferKey = message.transferKey ?: return
        if (transferKey !in cancelledTileTransfers) {
            message.tileChunkIndex?.let { chunkIndex ->
                val acknowledgedCount = acknowledgedTileChunks[transferKey] ?: 0
                if (chunkIndex >= acknowledgedCount) {
                    acknowledgedTileChunks[transferKey] = chunkIndex + 1
                }
            }
        }
        val transferDone = message.isFinalTileChunk ||
            transferKey in cancelledTileTransfers ||
            queue.none { it.transferKey == transferKey }
        if (!transferDone) {
            return
        }
        activeTileTransferKey = null
        cancelledTileTransfers.remove(transferKey)
        acknowledgedTileChunks.remove(transferKey)
        nextTileTransferAtMillis = monotonicMillis() + tileTransferPacingMillis.coerceAtLeast(0L)
    }

    private fun buildTileTransfer(fields: List<Map<String, Any?>>): QueuedTileTransfer? {
        if (fields.isEmpty()) {
            return null
        }
        val parsed = fields.map { TileChunk.fromFields(it) ?: return null }
        val identity = parsed.first().identity
        if (parsed.any { it.identity != identity }) {
            return null
        }

        val uniqueByChunkKey = linkedMapOf<String, TileChunk>()
        parsed.forEach { chunk ->
            val existing = uniqueByChunkKey[chunk.chunkKey]
            if (existing != null && !existing.data.contentEquals(chunk.data)) {
                return null
            }
            uniqueByChunkKey.putIfAbsent(chunk.chunkKey, chunk)
        }
        val ordered = uniqueByChunkKey.values.sortedBy { it.index }
        var expectedOffset = 0
        ordered.forEachIndexed { expectedIndex, chunk ->
            if (chunk.index != expectedIndex ||
                chunk.offset != expectedOffset ||
                chunk.data.isEmpty() ||
                chunk.data.size > MAX_WATCH_TILE_CHUNK_BYTES
            ) {
                return null
            }
            expectedOffset += chunk.data.size
        }
        if (expectedOffset != identity.totalBytes) {
            return null
        }

        return QueuedTileTransfer(
            requestKey = identity.requestKey,
            transferKey = identity.transferKey,
            requestId = identity.requestId,
            chunks = ordered.map { chunk ->
                QueuedMessage(
                    fields = chunk.fields,
                    priority = PRIORITY_TILE
                )
            }
        )
    }

    private fun tileBatchKey(fields: Map<String, Any?>): String =
        listOf(
            fields[KEY_WORLD_X],
            fields[KEY_WORLD_Y],
            fields[KEY_TILE_ZOOM],
            fields[KEY_REQUEST_ID]
        ).joinToString(":")

    private fun isZoomNotification(fields: Map<String, Any?>): Boolean =
        intValue(fields[KEY_CMD]) == CMD_BUTTON &&
            intValue(fields[KEY_BUTTON_ID]) in setOf(-1, 1)

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
            CMD_HAPTIC_MODE,
            CMD_GLANCE_MODE,
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

    private fun compareRequestIds(candidate: Int, existing: Int): Int {
        if (candidate == existing) {
            return 0
        }
        val modulus = Int.MAX_VALUE.toLong()
        val forwardDistance = (candidate.toLong() - existing.toLong() + modulus) % modulus
        return if (forwardDistance <= modulus / 2L) 1 else -1
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

    private fun emitStaleTileWorkDrop(request: Map<String, Any?>, responseCount: Int) {
        eventSink(
            mapOf(
                "event" to "tileWorkDrop",
                "reason" to REASON_STALE_TILE_WORK,
                KEY_WORLD_X to request[KEY_WORLD_X],
                KEY_WORLD_Y to request[KEY_WORLD_Y],
                KEY_TILE_ZOOM to request[KEY_TILE_ZOOM],
                KEY_REQUEST_ID to request[KEY_REQUEST_ID],
                "responseCount" to responseCount,
                "status" to status()
            )
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
            "requestKey" to message.requestKey,
            "transferKey" to message.transferKey,
            "chunkKey" to message.chunkKey
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
        private val tileChunk: TileChunk? = if (command == CMD_TILE) TileChunk.fromFields(fields) else null
        val requestKey: String? = tileChunk?.identity?.requestKey
        val transferKey: String? = tileChunk?.identity?.transferKey
        val requestId: Int? = tileChunk?.identity?.requestId
        val chunkKey: String? = tileChunk?.chunkKey
        val tileChunkIndex: Int? = tileChunk?.index
        val tileKey: String? = chunkKey
        val isFinalTileChunk: Boolean = tileChunk?.let {
            it.offset + it.data.size == it.identity.totalBytes
        } == true
        val maxAttempts: Int = when (command) {
            CMD_LOG_EVENT -> 1
            CMD_GPS -> 2
            else -> 3
        }
        val shouldRetry: Boolean = attempts < maxAttempts
    }

    private data class QueuedTileTransfer(
        val requestKey: String,
        val transferKey: String,
        val requestId: Int,
        val chunks: List<QueuedMessage>
    )

    private data class TileTransferIdentity(
        val worldX: Int,
        val worldY: Int,
        val zoom: Int,
        val requestId: Int,
        val width: Int,
        val height: Int,
        val totalBytes: Int
    ) {
        val requestKey: String = "$worldX:$worldY:$zoom"
        val transferKey: String = "$requestKey:$requestId:$width:$height:$totalBytes"
    }

    private data class TileChunk(
        val fields: Map<String, Any?>,
        val identity: TileTransferIdentity,
        val index: Int,
        val offset: Int,
        val data: ByteArray
    ) {
        val chunkKey: String = "${identity.transferKey}:$index:$offset"

        companion object {
            fun fromFields(fields: Map<String, Any?>): TileChunk? {
                fun number(key: String): Int? = (fields[key] as? Number)?.toInt()

                val identity = TileTransferIdentity(
                    worldX = number(KEY_WORLD_X) ?: return null,
                    worldY = number(KEY_WORLD_Y) ?: return null,
                    zoom = number(KEY_TILE_ZOOM) ?: return null,
                    requestId = number(KEY_REQUEST_ID)?.takeIf { it > 0 } ?: return null,
                    width = number(KEY_WIDTH)?.takeIf { it > 0 } ?: return null,
                    height = number(KEY_HEIGHT)?.takeIf { it > 0 } ?: return null,
                    totalBytes = number(KEY_TOTAL_BYTES)?.takeIf { it > 0 } ?: return null
                )
                val index = number(KEY_CHUNK_INDEX)?.takeIf { it >= 0 } ?: return null
                val offset = number(KEY_CHUNK_OFFSET)?.takeIf { it >= 0 } ?: return null
                val data = fields[KEY_CHUNK_DATA] as? ByteArray ?: return null
                return TileChunk(fields, identity, index, offset, data)
            }
        }
    }

    private data class SendFailureOutcome(
        val message: QueuedMessage,
        val result: String,
        val transactionId: Int,
        val terminal: Boolean,
        val tileDrop: DroppedMessage? = null
    )

    private data class DroppedMessage(
        val message: QueuedMessage,
        val reason: String
    )

    private companion object {
        private const val MAX_QUEUE_LENGTH = 64
        private const val DEFAULT_IN_FLIGHT_TIMEOUT_MILLIS = 2_000L
        private const val DEFAULT_TILE_TRANSFER_PACING_MILLIS = 30L
        private const val PRIORITY_CONTROL = 0
        private const val PRIORITY_GPS = 1
        private const val PRIORITY_DESTINATIONS = 2
        private const val PRIORITY_ROUTE = 3
        private const val PRIORITY_TILE = 4
        private const val PRIORITY_LOW = 5
        private const val REASON_QUEUE_OVERFLOW = "queueOverflow"
        private const val REASON_MAP_SETTINGS_CHANGED = "mapSettingsChanged"
        private const val REASON_SUPERSEDED_TILE = "supersededTile"
        private const val REASON_STALE_TILE_REQUEST = "staleTileRequest"
        private const val REASON_INVALID_TILE_TRANSFER = "invalidTileTransfer"
        private const val REASON_CANCELLED_TILE_TRANSFER = "cancelledTileTransfer"
        private const val REASON_ZOOM_CHANGED = "zoomChanged"
        private const val REASON_STALE_TILE_WORK = "staleTileWork"

        private fun monotonicMillis(): Long = System.nanoTime() / 1_000_000L

        private fun retryDelayMillis(attempts: Int): Long =
            if (attempts <= 1) 150L else 400L
    }
}
