package com.leapwardkoex.mappy

import java.io.ByteArrayOutputStream
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.tan

internal fun watchMessage(command: Int, fields: Map<String, Any?> = emptyMap()): Map<String, Any?> =
    LinkedHashMap<String, Any?>().apply {
        putAll(fields)
        put(KEY_CMD, command)
    }

internal fun tileDeliveryRetryMessage(event: Map<String, Any?>): Map<String, Any?>? {
    if (event["reason"] == "staleTileRequest") {
        return null
    }
    val worldX = (event[KEY_WORLD_X] as? Number)?.toInt() ?: return null
    val worldY = (event[KEY_WORLD_Y] as? Number)?.toInt() ?: return null
    val zoom = (event[KEY_TILE_ZOOM] as? Number)?.toInt() ?: return null
    val requestId = (event[KEY_REQUEST_ID] as? Number)?.toInt()?.takeIf { it > 0 } ?: return null
    return watchMessage(
        CMD_ERROR_STATE,
        mapOf(
            KEY_BUTTON_ID to ERROR_TILE_PROVIDER,
            KEY_CHUNK_INDEX to CMD_TILE_REQUEST,
            KEY_CHUNK_OFFSET to 0,
            KEY_INSTRUCTION to "Tile delivery dropped; retrying.",
            KEY_WORLD_X to worldX,
            KEY_WORLD_Y to worldY,
            KEY_TILE_ZOOM to zoom,
            KEY_TOTAL_BYTES to 1,
            KEY_REQUEST_ID to requestId
        )
    )
}

internal fun routeWindowPoints(
    points: List<Map<*, *>>,
    centerX: Int,
    centerY: Int,
    width: Int,
    height: Int
): List<Map<*, *>> {
    val halfWidth = (width.coerceAtLeast(1) / 2).coerceAtLeast(1)
    val halfHeight = (height.coerceAtLeast(1) / 2).coerceAtLeast(1)
    val minX = centerX - halfWidth
    val maxX = centerX + halfWidth
    val minY = centerY - halfHeight
    val maxY = centerY + halfHeight
    val worldPoints = points.mapNotNull { point ->
        val worldX = intValue(point, "worldX")
        val worldY = intValue(point, "worldY")
        if (worldX == null || worldY == null) {
            null
        } else {
            NativeRoutePointMap(worldX, worldY, point)
        }
    }
    if (worldPoints.size < 2) {
        return emptyList()
    }

    val selected = mutableListOf<Map<*, *>>()
    fun addPoint(point: NativeRoutePointMap) {
        if (selected.lastOrNull() !== point.raw) {
            selected.add(point.raw)
        }
    }
    for (index in 1 until worldPoints.size) {
        val previous = worldPoints[index - 1]
        val current = worldPoints[index]
        if (segmentIntersectsBounds(previous, current, minX, maxX, minY, maxY)) {
            addPoint(previous)
            addPoint(current)
        }
    }
    return downsampleRoutePointMaps(selected, MAX_ROUTE_POINTS)
}

private fun segmentIntersectsBounds(
    start: NativeRoutePointMap,
    end: NativeRoutePointMap,
    minX: Int,
    maxX: Int,
    minY: Int,
    maxY: Int
): Boolean {
    fun contains(point: NativeRoutePointMap): Boolean =
        point.worldX in minX..maxX && point.worldY in minY..maxY
    if (contains(start) || contains(end)) {
        return true
    }
    val segmentMinX = minOf(start.worldX, end.worldX)
    val segmentMaxX = maxOf(start.worldX, end.worldX)
    val segmentMinY = minOf(start.worldY, end.worldY)
    val segmentMaxY = maxOf(start.worldY, end.worldY)
    return segmentMaxX >= minX &&
        segmentMinX <= maxX &&
        segmentMaxY >= minY &&
        segmentMinY <= maxY
}

private fun downsampleRoutePointMaps(points: List<Map<*, *>>, maxPoints: Int): List<Map<*, *>> {
    if (points.size <= maxPoints) {
        return points
    }
    if (maxPoints < 2) {
        return emptyList()
    }
    val lastIndex = points.lastIndex
    return (0 until maxPoints)
        .map { index -> ((index.toLong() * lastIndex) / (maxPoints - 1)).toInt() }
        .distinct()
        .map { points[it] }
}

internal fun mapSettingsReason(
    previous: GoogleMapTilesProvider.MapTileSettings,
    next: GoogleMapTilesProvider.MapTileSettings
): Int =
    when {
        previous.mapSource != next.mapSource &&
            previous.watchTileWidth == next.watchTileWidth &&
            previous.watchTileHeight == next.watchTileHeight -> 1
        previous.mapSource == next.mapSource &&
            (
                previous.watchTileWidth != next.watchTileWidth ||
                    previous.watchTileHeight != next.watchTileHeight
                ) -> 2
        else -> 0
    }

internal fun encodeDestinations(destinations: List<NativeDestination>): ByteArray {
    val output = ByteArrayOutputStream()
    val records = destinations
    output.write(0x80 or records.size)
    records.forEach { destination ->
        val label = truncatedUtf8Bytes(destination.label, MAX_DESTINATION_LABEL_BYTES)
        output.write(destination.slot)
        output.write(destination.kind.coerceIn(0, 2))
        output.write(travelProtocolValue(destination.defaultTravelMode))
        writeInt32(output, (destination.latitude * 10_000_000.0).roundToInt())
        writeInt32(output, (destination.longitude * 10_000_000.0).roundToInt())
        output.write(label.size)
        output.write(label)
    }
    return output.toByteArray()
}

internal fun encodeRoutePoints(points: List<Map<*, *>>): ByteArray {
    val records = points
        .mapNotNull { point ->
            val worldX = intValue(point, "worldX")
            val worldY = intValue(point, "worldY")
            if (worldX == null || worldY == null) {
                null
            } else {
                worldX to worldY
            }
        }
        .take(MAX_ROUTE_POINTS)
    val output = ByteArrayOutputStream()
    writeUInt16(output, records.size)
    output.write(ROUTE_WORLD_ZOOM and 0x7f)
    records.forEach { (worldX, worldY) ->
        writeInt32(output, worldX)
        writeInt32(output, worldY)
    }
    return output.toByteArray()
}

internal fun encodeNavSteps(steps: List<Map<*, *>>, firstIndex: Int): ByteArray? {
    val chunk = steps
        .filter { (intValue(it, "index") ?: 0) >= firstIndex }
        .take(MAX_NAV_STEP_CHUNK)
    if (chunk.isEmpty()) {
        return null
    }
    val output = ByteArrayOutputStream()
    output.write(steps.size.coerceIn(0, 255))
    output.write(firstIndex.coerceIn(0, 255))
    output.write(chunk.size.coerceIn(1, MAX_NAV_STEP_CHUNK))
    chunk.forEach { step ->
        val instruction = truncatedUtf8Bytes(
            step["instruction"] as? String ?: "",
            MAX_WATCH_TEXT_BYTES
        )
        output.write((intValue(step, "index") ?: 0).coerceIn(0, 255))
        writeInt32(output, intValue(step, "startWorldX") ?: 0)
        writeInt32(output, intValue(step, "startWorldY") ?: 0)
        writeUInt16(output, (intValue(step, "remainingMeters") ?: 0).coerceIn(0, 65_535))
        writeUInt16(output, (intValue(step, "remainingSeconds") ?: 0).coerceIn(0, 65_535))
        output.write(instruction.size)
        output.write(instruction)
    }
    return output.toByteArray()
}

private fun writeUInt16(output: ByteArrayOutputStream, value: Int) {
    output.write(value and 0xFF)
    output.write((value ushr 8) and 0xFF)
}

private fun writeInt32(output: ByteArrayOutputStream, value: Int) {
    output.write(value and 0xFF)
    output.write((value ushr 8) and 0xFF)
    output.write((value ushr 16) and 0xFF)
    output.write((value ushr 24) and 0xFF)
}

internal fun truncatedUtf8Text(value: String, maxBytes: Int): String =
    String(truncatedUtf8Bytes(value, maxBytes), Charsets.UTF_8)

internal fun truncatedUtf8Bytes(value: String, maxBytes: Int): ByteArray {
    val output = ByteArrayOutputStream()
    var index = 0
    while (index < value.length) {
        val codePoint = value.codePointAt(index)
        val chunk = String(Character.toChars(codePoint)).toByteArray(Charsets.UTF_8)
        if (output.size() + chunk.size > maxBytes) {
            break
        }
        output.write(chunk)
        index += Character.charCount(codePoint)
    }
    return output.toByteArray()
}

internal fun worldPoint(latitude: Double, longitude: Double): Pair<Int, Int> {
    val scale = 1 shl ROUTE_WORLD_ZOOM
    val clampedLat = latitude.coerceIn(MIN_WEB_MERCATOR_LAT, MAX_WEB_MERCATOR_LAT)
    val wrappedLng = ((longitude + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
    val latRad = Math.toRadians(clampedLat)
    val worldX = ((wrappedLng + 180.0) / 360.0) * scale * SOURCE_TILE_SIZE
    val mercator = (1.0 - ln(tan(latRad) + 1.0 / cos(latRad)) / PI) / 2.0
    val worldY = mercator * scale * SOURCE_TILE_SIZE
    return worldX.roundToInt() to worldY.roundToInt()
}
