package com.leapwardkoex.mappy

import io.rebble.pebblekit2.common.model.PebbleDictionaryItem
import java.util.UUID
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
        transport.deliverWatchData(42, watchMessage(CMD_INIT))

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
        transport.deliverWatchData(2, watchMessage(CMD_INIT))
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

        repeat(3) {
            transport.nack(transport.sent.last().transactionId)
            waitUntil { transport.sent.size == it + 1 || transport.sent.size == it + 2 }
        }

        Thread.sleep(50)
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
    fun duplicateQueuedTileReportsSupersededTileDrop() {
        val transport = FakePebbleTransport(connected = false)
        val events = mutableListOf<Map<String, Any?>>()
        val bridge = WatchAppMessageBridge(
            uuid,
            transport,
            eventSink = { events.add(it) }
        ) { emptyList() }

        bridge.start()
        markWatchReady(transport)
        bridge.enqueue(tileMessage(7))
        bridge.enqueue(tileMessage(7))

        assertEquals(1, bridge.status()["queueLength"])
        assertTrue(
            events.any {
                it["event"] == "tileDrop" &&
                    it["reason"] == "supersededTile" &&
                    it[KEY_WORLD_X] == 7 &&
                    it[KEY_TILE_ZOOM] == 16
            }
        )
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
    fun nonTileResponseReportsDeliveryFailureAfterOneNack() {
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

        transport.nack(transport.sent.last().transactionId)

        Thread.sleep(50)
        assertEquals(1, transport.sent.size)
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
    fun destinationResponseReportsDeliveryFailureWithoutRetrying() {
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

        transport.nack(transport.sent.single().transactionId)

        Thread.sleep(50)
        assertEquals(1, transport.sent.size)
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
        assertEquals((50..69).toList(), ids.toList())
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
        watchMessage(
            CMD_TILE,
            mapOf(
                KEY_WORLD_X to index,
                KEY_WORLD_Y to index + 1,
                KEY_TILE_ZOOM to 16,
                KEY_TOTAL_BYTES to 1,
                KEY_CHUNK_DATA to byteArrayOf(index.toByte())
            )
        )

    private fun tileRequestMessage(index: Int): Map<String, Any?> =
        watchMessage(
            CMD_TILE_REQUEST,
            mapOf(
                KEY_WORLD_X to index,
                KEY_WORLD_Y to index + 1,
                KEY_TILE_ZOOM to 16,
                KEY_IS_COLOR to 0
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
        transport.deliverWatchData(1, watchMessage(CMD_INIT))
    }

    private class FakePebbleTransport(
        var connected: Boolean = true,
        var appActive: Boolean = true
    ) : PebbleTransport {
        private var receiver: PebbleTransportReceiver? = null
        val sent = mutableListOf<SentMessage>()
        val acks = mutableListOf<Int>()
        val nacks = mutableListOf<Int>()

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
            sent.add(SentMessage(transactionId, fields))
        }

        override fun sendAck(transactionId: Int) {
            acks.add(transactionId)
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
