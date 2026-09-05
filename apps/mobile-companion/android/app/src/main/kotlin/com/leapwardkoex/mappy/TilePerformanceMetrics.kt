package com.leapwardkoex.mappy

import kotlin.math.ceil

/** Bounded, memory-only phone measurements. ACK completion is not watch rendering. */
internal class TilePerformanceMetrics(
    private val capacity: Int = 512,
    private val monotonicMillis: () -> Long = { System.nanoTime() / 1_000_000L }
) {
    private data class Request(val started: Long, val values: MutableMap<String, Any?>)
    private val requests = linkedMapOf<Long, Request>()
    private var requestCount = 0L
    private var completedCount = 0L
    private var cancelledCount = 0L
    private var failedCount = 0L
    private var sendFailureCount = 0L
    private var transmittedBytes = 0L

    @Synchronized
    fun record(event: Map<String, Any?>) {
        val id = (event[KEY_REQUEST_ID] as? Number)?.toInt() ?: return
        val workId = (event[TILE_WORK_ID] as? Number)?.toLong() ?: id.toLong()
        val kind = event["event"]
        if (kind == "watchCommand" && event["command"] == CMD_TILE_REQUEST) {
            requests.remove(workId)
            requests[workId] = Request((event["receivedAtMillis"] as? Number)?.toLong() ?: monotonicMillis(), linkedMapOf("requestId" to id, "workId" to workId, "status" to "preparing"))
            requestCount++
            while (requests.size > capacity.coerceAtLeast(1)) requests.remove(requests.keys.first())
            return
        }
        val request = requests[workId] ?: return
        val values = request.values
        fun duration(name: String, value: Any?) {
            val number = (value as? Number)?.toDouble() ?: return
            if (number.isFinite() && number >= 0.0) values[name] = number
        }
        fun terminal(status: String) {
            if (values["status"] in setOf("acknowledged", "cancelled", "failed", "dropped")) return
            values["status"] = status
            values[if (status == "acknowledged") "completionMillis" else "terminationMillis"] =
                (monotonicMillis() - request.started).coerceAtLeast(0L)
            when (status) {
                "acknowledged" -> completedCount++
                "cancelled" -> cancelledCount++
                else -> failedCount++
            }
        }
        when (kind) {
            "tileWorkStarted" -> duration("workerWaitMillis", event["workerWaitMillis"])
            "tilePrepared" -> {
                val metrics = event["tileMetrics"] as? Map<*, *>
                metrics?.forEach { (key, value) ->
                    if (key is String && key in PREPARATION_FIELDS) duration(key, value)
                }
                val source = event["tile_source"] as? String
                if (source in setOf("rendered", "encodedCache", "duplicateInFlight")) values["source"] = source
                (event[KEY_TOTAL_BYTES] as? Number)?.let { values["payloadBytes"] = it.toInt() }
                (event[KEY_COMPRESSION_FORMAT] as? Number)?.let { values["codec"] = it.toInt() }
                if (values["status"] == "preparing") values["status"] = "prepared"
            }
            "sendResult" -> if (event["command"] == CMD_TILE) {
                val elapsed = (event["sendAckMillis"] as? Number)?.toDouble() ?: 0.0
                values["sendAckMillis"] = ((values["sendAckMillis"] as? Number)?.toDouble() ?: 0.0) + elapsed.coerceAtLeast(0.0)
                if (event[KEY_CHUNK_INDEX] == 0 && "queueWaitMillis" !in values) duration("queueWaitMillis", event["queueWaitMillis"])
                val bytes = (event["chunkBytes"] as? Number)?.toLong()?.coerceAtLeast(0L) ?: 0L
                transmittedBytes += bytes
                values["transmittedBytes"] = ((values["transmittedBytes"] as? Number)?.toLong() ?: 0L) + bytes
                if (event["result"] != "ack") {
                    sendFailureCount++
                    values["sendFailures"] = ((values["sendFailures"] as? Number)?.toInt() ?: 0) + 1
                } else {
                    values["acknowledgedChunks"] = ((values["acknowledgedChunks"] as? Number)?.toInt() ?: 0) + 1
                    if (event["finalChunk"] == true) terminal("acknowledged")
                }
            }
            "tileWorkDrop" -> terminal("cancelled")
            "tileDrop" -> terminal(if (event["reason"] in setOf("zoomChanged", "mapSettingsChanged", "staleTileWork", "cancelledTileTransfer", "stopped", "disconnected", "watchRestarted")) "cancelled" else "dropped")
            "deliveryFailure" -> if (event["command"] == CMD_TILE) terminal("failed")
            "tilePreparationFailed" -> terminal("failed")
        }
    }

    @Synchronized
    fun snapshot(): Map<String, Any?> {
        val history = requests.values.map { LinkedHashMap(it.values) }
        val timings = history.flatMap { it.keys }.filter { it.endsWith("Millis") }.distinct().associateWith { key ->
            val samples = history.mapNotNull { (it[key] as? Number)?.toDouble() }.sorted()
            fun percentile(fraction: Double): Double? = if (samples.isEmpty()) null else samples[(ceil(samples.size * fraction).toInt() - 1).coerceAtLeast(0)]
            mapOf("samples" to samples.size, "median" to percentile(0.5), "p95" to percentile(0.95))
        }
        val counts = setOf("sourceByteCacheHits", "sourcePixelCacheHits", "sharedSourceHits", "sharedRenderHits",
            "encodedCacheHits", "sourceRetries", "acknowledgedChunks").associateWith { field ->
            history.sumOf { (it[field] as? Number)?.toLong() ?: 0L }
        }
        return mapOf(
            "schemaVersion" to 1, "historyLimit" to capacity, "completionMeaning" to "phone request receipt to final transport ACK; not watch rendering",
            "requests" to requestCount, "acknowledged" to completedCount, "cancelled" to cancelledCount,
            "failedOrDropped" to failedCount, "sendFailures" to sendFailureCount, "transmittedBytes" to transmittedBytes,
            "retainedRequestTimingsMillis" to timings, "retainedRequestCounts" to counts, "history" to history
        )
    }

    private companion object {
        val PREPARATION_FIELDS = setOf(
            "fetchMillis", "decodeMillis", "cropMillis", "colorMillis", "encodeMillis", "sourceWaitMillis",
            "preparationMillis", "sessionMillis", "sourceByteCacheHits", "sourcePixelCacheHits", "sharedSourceHits", "sharedRenderHits",
            "encodedCacheHits", "sourceTiles", "sourceRetries", "payloadBytes", "rleBytes", "packedBytes"
        )
    }
}
