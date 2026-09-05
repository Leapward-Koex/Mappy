package com.leapwardkoex.mappy

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class TilePerformanceMetricsTest {
    @Test fun recordsWithoutUiAndBoundsHistoryWhileKeepingTotals() {
        var now = 10L
        val metrics = TilePerformanceMetrics(2) { now }
        for (id in 1..3) {
            metrics.record(mapOf("event" to "watchCommand", "command" to CMD_TILE_REQUEST, KEY_REQUEST_ID to id))
            now += 20
            metrics.record(mapOf("event" to "tilePrepared", KEY_REQUEST_ID to id, KEY_TOTAL_BYTES to 100,
                KEY_COMPRESSION_FORMAT to 4, "tileMetrics" to mapOf("fetchMillis" to 8, "secret" to "do not retain")))
            metrics.record(mapOf("event" to "sendResult", "command" to CMD_TILE, KEY_REQUEST_ID to id,
                KEY_CHUNK_INDEX to 0, "result" to "ack", "sendAckMillis" to 6, "queueWaitMillis" to 2,
                "chunkBytes" to 100, "finalChunk" to true))
        }
        val result = metrics.snapshot()
        assertEquals(3L, result["requests"])
        assertEquals(3L, result["acknowledged"])
        assertEquals(300L, result["transmittedBytes"])
        val history = result["history"] as List<*>
        assertEquals(2, history.size)
        assertFalse(result.toString().contains("do not retain"))
        assertTrue(result["completionMeaning"].toString().contains("not watch rendering"))
        val summaries = result["retainedRequestTimingsMillis"] as Map<*, *>
        assertEquals(20.0, (summaries["completionMillis"] as Map<*, *>)["p95"])
    }

    @Test fun cancellationIsTerminalEvenIfInFlightChunkLaterAcknowledges() {
        val metrics = TilePerformanceMetrics()
        metrics.record(mapOf("event" to "watchCommand", "command" to CMD_TILE_REQUEST, KEY_REQUEST_ID to 1))
        metrics.record(mapOf("event" to "tileWorkDrop", KEY_REQUEST_ID to 1))
        metrics.record(mapOf("event" to "sendResult", "command" to CMD_TILE, KEY_REQUEST_ID to 1,
            "result" to "ack", "finalChunk" to true))
        metrics.record(mapOf("event" to "tileWorkDrop", KEY_REQUEST_ID to 1))
        assertEquals(1L, metrics.snapshot()["cancelled"])
        assertEquals(0L, metrics.snapshot()["acknowledged"])
    }
    @Test fun reusedWireIdsAndRouteFailuresDoNotCorruptTileHistory() {
        val metrics = TilePerformanceMetrics()
        for (work in 10L..11L) metrics.record(mapOf("event" to "watchCommand", "command" to CMD_TILE_REQUEST,
            KEY_REQUEST_ID to 1, TILE_WORK_ID to work))
        metrics.record(mapOf("event" to "deliveryFailure", "command" to CMD_ROUTE_POINTS,
            KEY_REQUEST_ID to 1, TILE_WORK_ID to 11L))
        metrics.record(mapOf("event" to "tileWorkDrop", KEY_REQUEST_ID to 1, TILE_WORK_ID to 10L))
        metrics.record(mapOf("event" to "sendResult", "command" to CMD_TILE, KEY_REQUEST_ID to 1,
            TILE_WORK_ID to 11L, "result" to "ack", "finalChunk" to true))
        assertEquals(1L, metrics.snapshot()["acknowledged"])
        assertEquals(1L, metrics.snapshot()["cancelled"])
        assertEquals(0L, metrics.snapshot()["failedOrDropped"])
        assertEquals(2, (metrics.snapshot()["history"] as List<*>).size)
    }

}
