package com.leapwardkoex.mappy

import io.rebble.pebblekit2.common.model.PebbleDictionaryItem
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class WatchAppMessageBridgeTest {
    private val uuid = UUID.fromString("18b376dc-40ef-464f-abfb-b1612ea94f7d")

    @Test
    fun inboundWatchMessageIsAckedAndResponsesAreSentOneAtATime() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) {
            listOf(
                watchMessage(CMD_THEME, mapOf(KEY_BUTTON_ID to 1)),
                watchMessage(CMD_GPS, mapOf(KEY_WORLD_X to 10, KEY_WORLD_Y to 20))
            )
        }

        bridge.start()
        transport.deliverWatchData(
            42,
            watchMessage(CMD_INIT, mapOf(KEY_PROTOCOL_VERSION to WATCH_PROTOCOL_VERSION))
        )

        waitUntil { transport.sent.size == 1 }
        assertEquals(listOf(42), transport.acks)
        assertEquals(CMD_THEME, transport.sent.single().command)
        assertTrue(events.any { it["event"] == "watchCommand" && it["command"] == CMD_INIT })

        transport.ack(transport.sent.single().transactionId)
        waitUntil { transport.sent.size == 2 }
        assertEquals(CMD_GPS, transport.sent.last().command)
        assertTrue(events.any { it["event"] == "sendResult" && it["result"] == "ack" && it["command"] == CMD_THEME })
    }

    @Test
    fun inboundWatchLogForwardsBoundedSemanticFields() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        transport.deliverWatchData(
            43,
            watchMessage(
                CMD_LOG_EVENT,
                mapOf(
                    KEY_BUTTON_ID to 0,
                    KEY_CHUNK_OFFSET to 10,
                    KEY_CHUNK_INDEX to 2,
                    KEY_INSTRUCTION to "bearing reacquire"
                )
            )
        )

        waitUntil { events.any { it["event"] == "watchCommand" && it["command"] == CMD_LOG_EVENT } }
        val event = events.first { it["event"] == "watchCommand" && it["command"] == CMD_LOG_EVENT }
        assertEquals(0, event[KEY_BUTTON_ID])
        assertEquals(10, event[KEY_CHUNK_OFFSET])
        assertEquals(2, event[KEY_CHUNK_INDEX])
        assertEquals("bearing reacquire", event[KEY_INSTRUCTION])
        assertEquals(listOf(43), transport.acks)
    }

    @Test
    fun queuedGpsIsPrioritizedAheadOfTilesAfterCurrentSendSettles() {
        val transport = FakePebbleTransport()
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(tileMessage(1))
        waitUntil { transport.sent.size == 1 }

        bridge.enqueue(tileMessage(2))
        bridge.enqueue(watchMessage(CMD_GPS, mapOf(KEY_WORLD_X to 1, KEY_WORLD_Y to 2)))
        transport.ack(transport.sent.first().transactionId)

        waitUntil { transport.sent.size == 2 }
        assertEquals(CMD_GPS, transport.sent.last().command)
    }

    @Test
    fun queuedSettingsArePrioritizedAheadOfTilesAfterCurrentSendSettles() {
        val settingsCommands = listOf(
            CMD_THEME,
            CMD_TRAVEL_MODE,
            CMD_UNITS,
            CMD_BACKLIGHT,
            CMD_MAP_SETTINGS,
            CMD_MAP_ORIENTATION,
            CMD_TILE_ANIMATION
        )

        settingsCommands.forEachIndexed { index, command ->
            val transport = FakePebbleTransport()
            val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

            bridge.start()
            markWatchReady(transport)
            bridge.enqueue(tileMessage(index * 10 + 1))
            waitUntil { transport.sent.size == 1 }

            bridge.enqueue(tileMessage(index * 10 + 2))
            bridge.enqueue(watchMessage(command, mapOf(KEY_BUTTON_ID to 1, KEY_TOTAL_BYTES to 1)))
            transport.ack(transport.sent.first().transactionId)

            waitUntil { transport.sent.size == 2 }
            assertEquals(command, transport.sent.last().command)
        }
    }

    @Test
    fun staleQueuedGpsIsSuperseded() {
        val transport = FakePebbleTransport(connected = false)
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        bridge.enqueue(watchMessage(CMD_GPS, mapOf(KEY_WORLD_X to 1, KEY_WORLD_Y to 2)))
        bridge.enqueue(watchMessage(CMD_GPS, mapOf(KEY_WORLD_X to 3, KEY_WORLD_Y to 4)))
        transport.connected = true
        bridge.onWatchConnected()
        assertEquals(0, transport.sent.size)
        markWatchReady(transport)

        waitUntil { transport.sent.size == 1 }
        assertEquals(3, transport.sent.single().fields[KEY_WORLD_X])
        assertEquals(4, transport.sent.single().fields[KEY_WORLD_Y])
    }

    @Test
    fun connectedTransportDoesNotMarkWatchReadyBeforeInit() {
        val transport = FakePebbleTransport(connected = false)
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        transport.connected = true
        bridge.onWatchConnected()

        assertEquals(false, bridge.status()["watchReady"])
        assertEquals(0, transport.sent.size)
        transport.deliverWatchData(
            2,
            watchMessage(CMD_INIT, mapOf(KEY_PROTOCOL_VERSION to WATCH_PROTOCOL_VERSION))
        )
        assertEquals(true, bridge.status()["watchReady"])
    }

    @Test
    fun protocolMismatchIsAcknowledgedButDoesNotMarkWatchReady() {
        val transport = FakePebbleTransport()
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        transport.deliverWatchData(
            9,
            watchMessage(CMD_INIT, mapOf(KEY_PROTOCOL_VERSION to WATCH_PROTOCOL_VERSION - 1))
        )

        assertEquals(listOf(9), transport.acks)
        assertEquals(false, bridge.status()["watchReady"])
    }

    @Test
    fun validInboundTrafficRestoresWatchReadiness() {
        val transport = FakePebbleTransport()
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        transport.deliverWatchData(10, watchMessage(CMD_BUTTON, mapOf(KEY_BUTTON_ID to 1)))

        assertEquals(true, bridge.status()["watchReady"])
    }

    @Test
    fun statusReportsWatchAppActiveSeparatelyFromConnection() {
        val transport = FakePebbleTransport(connected = true, appActive = false)
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()

        assertEquals(true, bridge.status()["watchConnected"])
        assertEquals(false, bridge.status()["watchAppActive"])

        transport.appActive = true

        assertEquals(true, bridge.status()["watchAppActive"])
    }

    @Test
    fun disconnectRequeuesInFlightMessageForReconnect() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(watchMessage(CMD_ROUTE_POINTS, mapOf(KEY_CHUNK_DATA to byteArrayOf(1))))
        waitUntil { transport.sent.size == 1 }

        transport.connected = false
        bridge.onWatchDisconnected()

        assertEquals(false, bridge.status()["inFlight"])
        assertEquals(1, bridge.status()["queueLength"])
        assertTrue(events.any { it["event"] == "sendResult" && it["result"] == "disconnect" })

        transport.connected = true
        bridge.onWatchConnected()

        assertEquals(false, bridge.status()["watchReady"])
        assertEquals(1, transport.sent.size)
        markWatchReady(transport)
        waitUntil { transport.sent.size == 2 }
        assertEquals(CMD_ROUTE_POINTS, transport.sent.last().command)
    }

    @Test
    fun lostAckTimeoutRetriesAndDoesNotStallQueue() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            inFlightTimeoutMillis = 25L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(tileMessage(1))

        waitUntil { transport.sent.size >= 2 }
        assertEquals(CMD_TILE, transport.sent.last().command)
        assertTrue(events.any { it["event"] == "sendResult" && it["result"] == "timeout" })
        assertEquals(true, bridge.status()["inFlight"])
    }

    @Test
    fun synchronousAckCannotCancelTheNextMessagesWatchdog() {
        val transport = FakePebbleTransport()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            inFlightTimeoutMillis = 25L
        ) { emptyList() }
        var sends = 0
        transport.onSend = { sent ->
            sends++
            if (sends == 1) {
                transport.ack(sent.transactionId)
            }
        }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(watchMessage(CMD_THEME, mapOf(KEY_BUTTON_ID to 1)))
        bridge.enqueue(watchMessage(CMD_UNITS, mapOf(KEY_BUTTON_ID to 1)))

        waitUntil { transport.sent.size >= 3 }
        assertEquals(CMD_THEME, transport.sent[0].command)
        assertEquals(CMD_UNITS, transport.sent[1].command)
        assertEquals(CMD_UNITS, transport.sent[2].command)
        assertTrue(transport.sent[1].transactionId != transport.sent[2].transactionId)
        bridge.stop()
    }

    @Test
    fun noRouteBatchSendsZeroRoutePointsBeforeRouteError() {
        val transport = FakePebbleTransport()
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(
            listOf(
                watchMessage(CMD_ROUTE_POINTS, mapOf(KEY_CHUNK_DATA to byteArrayOf(0))),
                watchMessage(
                    CMD_ERROR_STATE,
                    mapOf(
                        KEY_BUTTON_ID to 7,
                        KEY_CHUNK_INDEX to CMD_ROUTE_REQUEST,
                        KEY_INSTRUCTION to "No route found."
                    )
                )
            )
        )

        waitUntil { transport.sent.size == 1 }
        assertEquals(CMD_ROUTE_POINTS, transport.sent.first().command)
        transport.ack(transport.sent.first().transactionId)
        waitUntil { transport.sent.size == 2 }
        assertEquals(CMD_ERROR_STATE, transport.sent.last().command)
    }

    @Test
    fun newerRouteBatchCancelsQueuedStaleRouteReplies() {
        val transport = FakePebbleTransport(connected = false)
        val bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        bridge.enqueueAll(
            listOf(
                watchMessage(CMD_ROUTE_POINTS, mapOf(KEY_CHUNK_DATA to byteArrayOf(1))),
                watchMessage(CMD_NAV_STEPS, mapOf(KEY_CHUNK_DATA to byteArrayOf(2)))
            )
        )
        bridge.enqueueAll(
            listOf(
                watchMessage(CMD_ROUTE_POINTS, mapOf(KEY_CHUNK_DATA to byteArrayOf(9)))
            )
        )

        transport.connected = true
        bridge.onWatchConnected()
        markWatchReady(transport)

        waitUntil { transport.sent.size == 1 }
        assertEquals(CMD_ROUTE_POINTS, transport.sent.single().command)
        assertTrue((transport.sent.single().fields[KEY_CHUNK_DATA] as ByteArray).contentEquals(byteArrayOf(9)))
        assertEquals(0, bridge.status()["queueLength"])
    }

    @Test
    fun tileResponseDropsAfterThreeNacks() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(tileMessage(1))
        waitUntil { transport.sent.size == 1 }

        repeat(3) { attempt ->
            transport.nack(transport.sent.last().transactionId)
            if (attempt < 2) waitUntil { transport.sent.size == attempt + 2 }
        }

        waitUntil { bridge.status()["inFlight"] == false && bridge.status()["queueLength"] == 0 }
        assertEquals(3, transport.sent.size)
        assertEquals(0, bridge.status()["queueLength"])
        assertEquals(false, bridge.status()["inFlight"])
        assertTrue(
            events.any {
                it["event"] == "tileDrop" &&
                    it["reason"] == "drop" &&
                    it["command"] == CMD_TILE &&
                    it[KEY_WORLD_X] == 1
            }
        )
    }

    @Test
    fun tileQueueOverflowReportsDroppedTile() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        repeat(65) { index ->
            bridge.enqueue(tileMessage(index))
        }

        assertTrue(
            events.any {
                it["event"] == "tileDrop" &&
                    it["reason"] == "queueOverflow" &&
                    it["command"] == CMD_TILE
            }
        )
    }

    @Test
    fun exactDuplicateTileTransferIsIgnoredWithoutDroppingSiblingChunks() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        val transfer = tileTransfer(7, requestId = 70, chunkSizes = listOf(20, 20, 20))
        bridge.enqueueAll(transfer)
        bridge.enqueueAll(transfer)

        assertEquals(3, bridge.status()["queueLength"])
        assertFalse(events.any { it["event"] == "tileDrop" })
    }

    @Test
    fun duplicateTransferAfterPartialAckDoesNotReappendAcknowledgedChunks() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }
        val transfer = tileTransfer(7, requestId = 70, chunkSizes = listOf(20, 20, 20))

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(transfer)
        waitUntil { transport.sent.size == 1 }
        transport.ack(transport.sent[0].transactionId)
        waitUntil { transport.sent.size == 2 }

        bridge.enqueueAll(transfer)
        assertEquals(1, bridge.status()["queueLength"])
        transport.ack(transport.sent[1].transactionId)
        waitUntil { transport.sent.size == 3 }
        transport.ack(transport.sent[2].transactionId)

        waitUntil { bridge.status()["inFlight"] == false }
        assertEquals(listOf(0, 1, 2), transport.sent.map { it.fields[KEY_CHUNK_INDEX] })
        assertFalse(events.any { it["event"] == "tileDrop" })
    }

    @Test
    fun fiveChunkTileTransferIsSentContiguouslyAndInOrder() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(
            tileTransfer(
                7,
                requestId = 70,
                chunkSizes = listOf(3072, 3072, 3072, 3072, 123)
            )
        )

        repeat(5) { index ->
            waitUntil { transport.sent.size == index + 1 }
            assertEquals(index, transport.sent[index].fields[KEY_CHUNK_INDEX])
            assertEquals(70, transport.sent[index].fields[KEY_REQUEST_ID])
            transport.ack(transport.sent[index].transactionId)
        }

        assertEquals(0, bridge.status()["queueLength"])
        assertFalse(events.any { it["event"] == "tileDrop" })
    }

    @Test
    fun secondTileTransferCannotInterleaveButControlCanPreemptBetweenChunks() {
        val transport = FakePebbleTransport()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(10, requestId = 100, chunkSizes = listOf(10, 10, 10)))
        waitUntil { transport.sent.size == 1 }
        bridge.enqueueAll(tileTransfer(20, requestId = 200, chunkSizes = listOf(10, 10)))
        bridge.enqueue(watchMessage(CMD_GPS, mapOf(KEY_WORLD_X to 1, KEY_WORLD_Y to 2)))

        transport.ack(transport.sent[0].transactionId)
        waitUntil { transport.sent.size == 2 }
        assertEquals(CMD_GPS, transport.sent[1].command)
        transport.ack(transport.sent[1].transactionId)

        repeat(4) { offset ->
            waitUntil { transport.sent.size == offset + 3 }
            transport.ack(transport.sent[offset + 2].transactionId)
        }

        val tileMessages = transport.sent.filter { it.command == CMD_TILE }
        assertEquals(listOf(100, 100, 100, 200, 200), tileMessages.map { it.fields[KEY_REQUEST_ID] })
        assertEquals(listOf(0, 1, 2, 0, 1), tileMessages.map { it.fields[KEY_CHUNK_INDEX] })
    }

    @Test
    fun newerRequestReplacesTheWholeQueuedTransferForItsCoordinate() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(5, requestId = 10, chunkSizes = listOf(10, 10, 10)))
        bridge.enqueueAll(tileTransfer(5, requestId = 11, chunkSizes = listOf(20, 20)))

        assertEquals(2, bridge.status()["queueLength"])
        assertEquals(1, events.count { it["event"] == "tileDrop" && it["reason"] == "supersededTile" })

        transport.connected = true
        bridge.onWatchConnected()
        waitUntil { transport.sent.size == 1 }
        assertEquals(11, transport.sent.single().fields[KEY_REQUEST_ID])
        assertEquals(0, transport.sent.single().fields[KEY_CHUNK_INDEX])
    }

    @Test
    fun olderLateRequestCannotSupersedeANewerQueuedTransfer() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(6, requestId = 11, chunkSizes = listOf(20, 20)))
        bridge.enqueueAll(tileTransfer(6, requestId = 10, chunkSizes = listOf(10, 10, 10)))

        assertEquals(2, bridge.status()["queueLength"])
        assertEquals(1, events.count { it["event"] == "tileDrop" && it["reason"] == "staleTileRequest" })

        transport.connected = true
        bridge.onWatchConnected()
        waitUntil { transport.sent.size == 1 }
        assertEquals(11, transport.sent.single().fields[KEY_REQUEST_ID])
    }

    @Test
    fun olderLateRequestCannotSupersedeANewerInFlightTransfer() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(6, requestId = 11, chunkSizes = listOf(20, 20, 20)))
        waitUntil { transport.sent.size == 1 }
        bridge.enqueueAll(tileTransfer(6, requestId = 10, chunkSizes = listOf(10, 10)))

        assertEquals(2, bridge.status()["queueLength"])
        assertEquals(1, events.count { it["event"] == "tileDrop" && it["reason"] == "staleTileRequest" })
        repeat(3) { index ->
            transport.ack(transport.sent[index].transactionId)
            if (index < 2) waitUntil { transport.sent.size == index + 2 }
        }
        assertEquals(listOf(11, 11, 11), transport.sent.map { it.fields[KEY_REQUEST_ID] })
    }

    @Test
    fun requestIdWrapTreatsOneAsNewerThanMaxPositiveId() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(6, requestId = Int.MAX_VALUE, chunkSizes = listOf(20, 20)))
        bridge.enqueueAll(tileTransfer(6, requestId = 1, chunkSizes = listOf(10)))

        assertEquals(1, bridge.status()["queueLength"])
        assertEquals(1, events.count { it["event"] == "tileDrop" && it["reason"] == "supersededTile" })
        transport.connected = true
        bridge.onWatchConnected()
        waitUntil { transport.sent.size == 1 }
        assertEquals(1, transport.sent.single().fields[KEY_REQUEST_ID])
    }

    @Test
    fun malformedTileBatchIsRejectedAtomically() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }
        val missingMiddleChunk = tileTransfer(
            8,
            requestId = 80,
            chunkSizes = listOf(100, 100, 100)
        ).filter { it[KEY_CHUNK_INDEX] != 1 }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(missingMiddleChunk)
        bridge.enqueueAll(tileTransfer(9, requestId = 90, chunkSizes = listOf(3073)))

        assertEquals(0, bridge.status()["queueLength"])
        assertEquals(2, events.count { it["event"] == "tileDrop" && it["reason"] == "invalidTileTransfer" })
    }

    @Test
    fun queueOverflowDropsTheOldestLogicalTransferOnce() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        repeat(22) { index ->
            bridge.enqueueAll(
                tileTransfer(
                    worldX = index,
                    requestId = index + 1,
                    chunkSizes = listOf(10, 10, 10)
                )
            )
        }

        val overflowDrops = events.filter {
            it["event"] == "tileDrop" && it["reason"] == "queueOverflow"
        }
        assertEquals(63, bridge.status()["queueLength"])
        assertEquals(1, overflowDrops.size)
        assertEquals(0, overflowDrops.single()[KEY_CHUNK_INDEX])
        assertTrue(overflowDrops.all { it[KEY_REQUEST_ID] == 1 })
    }

    @Test
    fun terminalChunkFailureDropsTheRestOfTheLogicalTransfer() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(12, requestId = 120, chunkSizes = listOf(20, 20, 20)))
        waitUntil { transport.sent.size == 1 }

        repeat(3) { attempt ->
            transport.nack(transport.sent.last().transactionId)
            if (attempt < 2) waitUntil { transport.sent.size == attempt + 2 }
        }

        waitUntil { bridge.status()["inFlight"] == false && bridge.status()["queueLength"] == 0 }
        assertEquals(listOf(0, 0, 0), transport.sent.map { it.fields[KEY_CHUNK_INDEX] })
        assertEquals(1, events.count { it["event"] == "tileDrop" })
    }

    @Test
    fun zoomCancellationPurgesTileTransfersBeforeAcknowledgement() {
        val transport = FakePebbleTransport(connected = false)
        lateinit var bridge: WatchAppMessageBridge
        var queueLengthAtAck: Any? = null
        var epochAtAck: Any? = null
        transport.onSendAck = {
            queueLengthAtAck = bridge.status()["queueLength"]
            epochAtAck = bridge.status()["tileWorkEpoch"]
        }
        bridge = WatchAppMessageBridge(uuid, transport) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(14, requestId = 140, chunkSizes = listOf(20, 20, 20)))
        transport.deliverWatchData(9, watchMessage(CMD_BUTTON, mapOf(KEY_BUTTON_ID to 1)))

        assertEquals(0, queueLengthAtAck)
        assertEquals(1L, epochAtAck)
        assertEquals(listOf(1, 9), transport.acks)
    }

    @Test
    fun zoomCancellationStopsRemainingChunksOfAnInFlightTransfer() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) },
            tileTransferPacingMillis = 0L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(16, requestId = 160, chunkSizes = listOf(20, 20, 20)))
        waitUntil { transport.sent.size == 1 }

        transport.deliverWatchData(10, watchMessage(CMD_BUTTON, mapOf(KEY_BUTTON_ID to 1)))
        assertEquals(0, bridge.status()["queueLength"])
        assertEquals(true, bridge.status()["inFlight"])
        transport.ack(transport.sent.single().transactionId)

        waitUntil { bridge.status()["inFlight"] == false }
        Thread.sleep(50)
        assertEquals(1, transport.sent.size)
        assertEquals(1, events.count { it["event"] == "tileDrop" && it["reason"] == "zoomChanged" })
    }

    @Test
    fun providerResultFromAnOlderZoomEpochIsDiscarded() {
        val transport = FakePebbleTransport(connected = false)
        val dispatchStarted = CountDownLatch(1)
        val releaseDispatch = CountDownLatch(1)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { message ->
            if ((message[KEY_CMD] as? Number)?.toInt() == CMD_TILE_REQUEST) {
                dispatchStarted.countDown()
                releaseDispatch.await(1, TimeUnit.SECONDS)
                tileTransfer(18, requestId = 180, chunkSizes = listOf(50, 50, 50))
            } else {
                emptyList()
            }
        }

        bridge.start()
        markWatchReady(transport)
        transport.deliverWatchData(2, tileRequestMessage(18))
        assertTrue(dispatchStarted.await(1, TimeUnit.SECONDS))
        transport.deliverWatchData(3, watchMessage(CMD_BUTTON, mapOf(KEY_BUTTON_ID to -1)))
        releaseDispatch.countDown()

        waitUntil { events.any { it["event"] == "tileWorkDrop" && it["reason"] == "staleTileWork" } }
        assertEquals(0, bridge.status()["queueLength"])
    }

    @Test
    fun completeTileTransfersArePacedButControlBypassesTheCooldown() {
        val transport = FakePebbleTransport()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            tileTransferPacingMillis = 150L
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(tileTransfer(21, requestId = 210, chunkSizes = listOf(10)))
        bridge.enqueueAll(tileTransfer(22, requestId = 220, chunkSizes = listOf(10)))
        waitUntil { transport.sent.size == 1 }
        val ackAtNanos = System.nanoTime()
        transport.ack(transport.sent[0].transactionId)
        bridge.enqueue(watchMessage(CMD_GPS, mapOf(KEY_WORLD_X to 1, KEY_WORLD_Y to 2)))

        waitUntil { transport.sent.size == 2 }
        assertEquals(CMD_GPS, transport.sent[1].command)
        transport.ack(transport.sent[1].transactionId)
        waitUntil { transport.sent.size == 3 }
        val elapsedMillis = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - ackAtNanos)
        assertEquals(220, transport.sent[2].fields[KEY_REQUEST_ID])
        assertTrue(elapsedMillis >= 100L, "Expected tile pacing, observed ${elapsedMillis}ms")
    }

    @Test
    fun runtimeOwnedTileDropRetryPreservesTheLogicalRequestId() {
        val retry = requireNotNull(
            tileDeliveryRetryMessage(
                mapOf(
                    "event" to "tileDrop",
                    "reason" to "zoomChanged",
                    KEY_WORLD_X to 12,
                    KEY_WORLD_Y to 34,
                    KEY_TILE_ZOOM to 16,
                    KEY_REQUEST_ID to 567
                )
            )
        )

        assertEquals(CMD_ERROR_STATE, retry[KEY_CMD])
        assertEquals(ERROR_TILE_PROVIDER, retry[KEY_BUTTON_ID])
        assertEquals(CMD_TILE_REQUEST, retry[KEY_CHUNK_INDEX])
        assertEquals(1, retry[KEY_TOTAL_BYTES])
        assertEquals(12, retry[KEY_WORLD_X])
        assertEquals(34, retry[KEY_WORLD_Y])
        assertEquals(16, retry[KEY_TILE_ZOOM])
        assertEquals(567, retry[KEY_REQUEST_ID])
    }

    @Test
    fun runtimeOwnedTileDropRetryIgnoresStaleOrUnmatchableRequests() {
        val base = mapOf<String, Any?>(
            "event" to "tileDrop",
            KEY_WORLD_X to 12,
            KEY_WORLD_Y to 34,
            KEY_TILE_ZOOM to 16,
            KEY_REQUEST_ID to 567
        )

        assertEquals(null, tileDeliveryRetryMessage(base + ("reason" to "staleTileRequest")))
        assertEquals(null, tileDeliveryRetryMessage(base + (KEY_REQUEST_ID to 0)))
        assertEquals(null, tileDeliveryRetryMessage(base - KEY_WORLD_X))
    }

    @Test
    fun queuedTileResponsesAreLeftForWatchSideStaleFiltering() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        repeat(50) { index ->
            transport.deliverWatchData(index + 2, tileRequestMessage(index))
        }
        bridge.enqueue(tileMessage(0))

        assertEquals(1, bridge.status()["queueLength"])

        transport.deliverWatchData(99, tileRequestMessage(50))

        assertEquals(1, bridge.status()["queueLength"])
        assertFalse(events.any { it["event"] == "tileDrop" })
    }

    @Test
    fun mapSettingsDropQueuedTileResponses() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(tileMessage(1))
        bridge.enqueue(tileMessage(2))
        bridge.enqueue(mapSettingsMessage(width = 72, height = 84))

        assertEquals(1, bridge.status()["queueLength"])
        assertEquals(2, events.count { it["event"] == "tileDrop" && it["reason"] == "mapSettingsChanged" })

        transport.connected = true
        bridge.onWatchConnected()

        waitUntil { transport.sent.size == 1 }
        assertEquals(CMD_MAP_SETTINGS, transport.sent.single().command)
    }

    @Test
    fun mapSettingsBatchDropsTileResponsesFromSameBatch() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueueAll(
            listOf(
                mapSettingsMessage(width = 108, height = 126),
                tileMessage(1)
            )
        )

        assertEquals(1, bridge.status()["queueLength"])
        assertEquals(1, events.count { it["event"] == "tileDrop" && it["reason"] == "mapSettingsChanged" })

        transport.connected = true
        bridge.onWatchConnected()

        waitUntil { transport.sent.size == 1 }
        assertEquals(CMD_MAP_SETTINGS, transport.sent.single().command)
    }

    @Test
    fun nonTileResponseReportsDeliveryFailureAfterThreeAttempts() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(watchMessage(CMD_ROUTE_POINTS, mapOf(KEY_CHUNK_DATA to byteArrayOf(1, 2, 3))))
        waitUntil { transport.sent.size == 1 }

        repeat(3) { attempt ->
            transport.nack(transport.sent.last().transactionId)
            if (attempt < 2) waitUntil { transport.sent.size == attempt + 2 }
        }

        waitUntil { bridge.status()["inFlight"] == false && bridge.status()["queueLength"] == 0 }
        assertEquals(3, transport.sent.size)
        assertEquals(0, bridge.status()["queueLength"])
        assertEquals(false, bridge.status()["inFlight"])
        assertTrue(events.any { it["event"] == "sendResult" && it["result"] == "failed" })
        assertTrue(
            events.any {
                it["event"] == "deliveryFailure" &&
                    it["result"] == "failed" &&
                    it["command"] == CMD_ROUTE_POINTS &&
                    it["droppable"] == false
            }
        )
    }

    @Test
    fun destinationResponseReportsDeliveryFailureAfterThreeAttempts() {
        val transport = FakePebbleTransport()
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(watchMessage(CMD_DESTINATIONS, mapOf(KEY_CHUNK_DATA to byteArrayOf(1, 2, 3))))
        waitUntil { transport.sent.size == 1 }

        repeat(3) { attempt ->
            transport.nack(transport.sent.last().transactionId)
            if (attempt < 2) waitUntil { transport.sent.size == attempt + 2 }
        }

        waitUntil { bridge.status()["inFlight"] == false && bridge.status()["queueLength"] == 0 }
        assertEquals(3, transport.sent.size)
        assertEquals(false, bridge.status()["inFlight"])
        assertTrue(
            events.any {
                it["event"] == "deliveryFailure" &&
                    it["result"] == "failed" &&
                    it["command"] == CMD_DESTINATIONS &&
                    it["droppable"] == false
            }
        )
    }

    @Test
    fun pebbleDictionaryCodecRoundTripsProtocolFields() {
        val fields = watchMessage(
            CMD_TILE,
            mapOf(
                KEY_WORLD_X to 123,
                KEY_WORLD_Y to 456,
                KEY_TILE_ZOOM to 16,
                KEY_TOTAL_BYTES to 3,
                KEY_CHUNK_DATA to byteArrayOf(1, 2, 3),
                KEY_INSTRUCTION to "ok"
            )
        )

        val decoded = PebbleAppMessageCodec.decode(PebbleAppMessageCodec.encode(fields))

        assertEquals(CMD_TILE, decoded[KEY_CMD])
        assertEquals(123, decoded[KEY_WORLD_X])
        assertEquals("ok", decoded[KEY_INSTRUCTION])
        assertTrue((decoded[KEY_CHUNK_DATA] as ByteArray).contentEquals(byteArrayOf(1, 2, 3)))
    }

    @Test
    fun appMessageKeyIdsUseMappyOwnedProtocolBlock() {
        val ids = WATCH_MESSAGE_KEY_IDS.values

        assertEquals(ids.size, ids.toSet().size)
        assertEquals((50..71).toList(), ids.toList())
    }

    @Test
    fun routePointPayloadUsesCompactLittleEndianProtocolEncoding() {
        val payload = encodeRoutePoints(
            listOf(mapOf("worldX" to 0x01020304, "worldY" to -2))
        )

        assertTrue(
            payload.contentEquals(
                byteArrayOf(1, 0, 16, 4, 3, 2, 1, -2, -1, -1, -1)
            )
        )
    }

    @Test
    fun declinationCommandRoundTripsSignedCentidegrees() {
        val fields = watchMessage(
            CMD_DECLINATION,
            mapOf(KEY_BUTTON_ID to -12_345)
        )

        val decoded = PebbleAppMessageCodec.decode(PebbleAppMessageCodec.encode(fields))

        assertEquals(CMD_DECLINATION, decoded[KEY_CMD])
        assertEquals(-12_345, decoded[KEY_BUTTON_ID])
    }

    @Test
    fun pebbleKit2DictionaryCodecRoundTripsProtocolFields() {
        val fields = watchMessage(
            CMD_TILE,
            mapOf(
                KEY_WORLD_X to 123,
                KEY_WORLD_Y to 456,
                KEY_TILE_ZOOM to 16,
                KEY_TOTAL_BYTES to 3,
                KEY_CHUNK_DATA to byteArrayOf(1, 2, 3),
                KEY_INSTRUCTION to "ok"
            )
        )

        val encoded = PebbleKit2AppMessageCodec.encode(fields)
        val decoded = PebbleKit2AppMessageCodec.decode(encoded)

        val commandKey = WATCH_MESSAGE_KEY_IDS.getValue(KEY_CMD).toUInt()
        assertEquals(PebbleDictionaryItem.Int32(CMD_TILE), encoded[commandKey])
        assertEquals(CMD_TILE, decoded[KEY_CMD])
        assertEquals(123, decoded[KEY_WORLD_X])
        assertEquals("ok", decoded[KEY_INSTRUCTION])
        assertTrue((decoded[KEY_CHUNK_DATA] as ByteArray).contentEquals(byteArrayOf(1, 2, 3)))
    }

    private fun tileMessage(index: Int): Map<String, Any?> =
        tileTransfer(
            worldX = index,
            requestId = index.coerceAtLeast(1),
            chunkSizes = listOf(1)
        ).single()

    private fun tileTransfer(
        worldX: Int,
        requestId: Int,
        chunkSizes: List<Int>,
        zoom: Int = 16
    ): List<Map<String, Any?>> {
        val totalBytes = chunkSizes.sum()
        var offset = 0
        return chunkSizes.mapIndexed { index, chunkSize ->
            watchMessage(
                CMD_TILE,
                mapOf(
                    KEY_WORLD_X to worldX,
                    KEY_WORLD_Y to worldX + 1,
                    KEY_TILE_ZOOM to zoom,
                    KEY_WIDTH to 54,
                    KEY_HEIGHT to 63,
                    KEY_TOTAL_BYTES to totalBytes,
                    KEY_CHUNK_INDEX to index,
                    KEY_CHUNK_OFFSET to offset,
                    KEY_REQUEST_ID to requestId,
                    KEY_CHUNK_DATA to ByteArray(chunkSize) { (index + 1).toByte() }
                )
            ).also { offset += chunkSize }
        }
    }

    private fun tileRequestMessage(index: Int): Map<String, Any?> =
        watchMessage(
            CMD_TILE_REQUEST,
            mapOf(
                KEY_WORLD_X to index,
                KEY_WORLD_Y to index + 1,
                KEY_TILE_ZOOM to 16,
                KEY_IS_COLOR to 0,
                KEY_REQUEST_ID to (index + 1)
            )
        )

    private fun mapSettingsMessage(width: Int, height: Int): Map<String, Any?> =
        watchMessage(
            CMD_MAP_SETTINGS,
            mapOf(
                KEY_BUTTON_ID to 2,
                KEY_WIDTH to width,
                KEY_HEIGHT to height,
                KEY_TOTAL_BYTES to 1
            )
        )

    private fun waitUntil(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 1_000L
        while (System.currentTimeMillis() < deadline) {
            if (condition()) {
                return
            }
            Thread.sleep(10)
        }
        assertTrue(condition())
    }

    private fun markWatchReady(transport: FakePebbleTransport) {
        transport.deliverWatchData(
            1,
            watchMessage(CMD_INIT, mapOf(KEY_PROTOCOL_VERSION to WATCH_PROTOCOL_VERSION))
        )
    }

    private class FakePebbleTransport(
        var connected: Boolean = true,
        var appActive: Boolean = true
    ) : PebbleTransport {
        private var receiver: PebbleTransportReceiver? = null
        val sent = mutableListOf<SentMessage>()
        val acks = mutableListOf<Int>()
        val nacks = mutableListOf<Int>()
        var onSendAck: ((Int) -> Unit)? = null
        var onSend: ((SentMessage) -> Unit)? = null

        override fun register(uuid: UUID, receiver: PebbleTransportReceiver) {
            this.receiver = receiver
        }

        override fun unregister() {
            receiver = null
        }

        override fun isWatchConnected(): Boolean = connected

        override fun isWatchAppActive(uuid: UUID): Boolean = connected && appActive

        override fun startWatchApp(uuid: UUID) {
        }

        override fun stopWatchApp(uuid: UUID) {
        }

        override fun send(uuid: UUID, transactionId: Int, fields: Map<String, Any?>) {
            val message = SentMessage(transactionId, fields)
            sent.add(message)
            onSend?.invoke(message)
        }

        override fun sendAck(transactionId: Int) {
            acks.add(transactionId)
            onSendAck?.invoke(transactionId)
        }

        override fun sendNack(transactionId: Int) {
            nacks.add(transactionId)
        }

        fun deliverWatchData(transactionId: Int, fields: Map<String, Any?>) {
            receiver?.onWatchData(transactionId, fields)
        }

        fun ack(transactionId: Int) {
            receiver?.onWatchAck(transactionId)
        }

        fun nack(transactionId: Int) {
            receiver?.onWatchNack(transactionId)
        }
    }

    private data class SentMessage(
        val transactionId: Int,
        val fields: Map<String, Any?>
    ) {
        val command: Int? = (fields[KEY_CMD] as? Number)?.toInt()
    }

}
