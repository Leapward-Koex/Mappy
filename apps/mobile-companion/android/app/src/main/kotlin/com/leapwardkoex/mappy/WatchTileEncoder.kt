package com.leapwardkoex.mappy

import net.jpountz.lz4.LZ4Factory
import kotlin.math.pow
import kotlin.math.roundToInt

internal data class EncodedWatchTile(
    val width: Int,
    val height: Int,
    val format: Int,
    val payload: ByteArray,
    val preparationMetrics: Map<String, Any> = emptyMap()
)

internal data class WatchTilePreparation(
    val worldX: Int,
    val worldY: Int,
    val zoom: Int,
    val encoded: EncodedWatchTile?,
    val providerStatus: Map<String, Any?>,
    val source: String? = null,
    val failure: Map<String, Any?>? = null
) {
    val ok: Boolean get() = encoded != null

    fun toMap(): Map<String, Any?> {
        val coordinates = mapOf("world_x" to worldX, "world_y" to worldY, "tile_zoom" to zoom)
        val tile = encoded ?: return failure.orEmpty() + coordinates
        return coordinates + mapOf(
            "ok" to true, "providerStatus" to providerStatus,
            "width" to tile.width, "height" to tile.height,
            "total_bytes" to tile.payload.size, "chunk_data" to tile.payload,
            "compression_format" to tile.format, "preparation_metrics" to tile.preparationMetrics,
            "tile_source" to source, "attribution" to "Google Map Tiles"
        )
    }
}

/** The LUT uses exactly the old floating-point operations, including rounding. */
internal object DayTileColors {
    val palette = intArrayOf(
        0xFFFFFF, 0xFFAAFF, 0xAAAAFF, 0xAAAAAA, 0xAA55AA, 0x555555, 0x000000, 0x55FFFF,
        0x00AAFF, 0x0055FF, 0xAAFFAA, 0x55FFAA, 0xFFFFAA, 0xFFFF00, 0xFFAA00, 0xAAAA55
    )
    private val brightness = IntArray(256) { (it - 10).coerceAtLeast(0) }
    private val channels by lazy {
        ByteArray(736 * 246) { index ->
            val average = (index / 246).toDouble() / 3.0
            val channel = (index % 246).toDouble()
            val saturated = (average + (channel - average) * 3.0).coerceIn(0.0, 255.0)
            val gamma = (saturated / 255.0).pow(1.8) * 255.0
            ((gamma.roundToInt() + 42) / 85).coerceIn(0, 3).toByte()
        }
    }
    private val paletteIndexes = IntArray(64) { pebble ->
        val red = ((pebble ushr 4) and 3) * 85
        val green = ((pebble ushr 2) and 3) * 85
        val blue = (pebble and 3) * 85
        var best = 0
        var distance = Int.MAX_VALUE
        palette.forEachIndexed { index, rgb ->
            val dr = red - ((rgb ushr 16) and 255)
            val dg = green - ((rgb ushr 8) and 255)
            val db = blue - (rgb and 255)
            val candidate = dr * dr + dg * dg + db * db
            if (candidate < distance) { best = index; distance = candidate }
        }
        best
    }

    fun paletteIndex(color: Int): Int {
        val red = brightness[(color ushr 16) and 255]
        val green = brightness[(color ushr 8) and 255]
        val blue = brightness[color and 255]
        val offset = (red + green + blue) * 246
        val lookup = channels
        return paletteIndexes[(lookup[offset + red].toInt() shl 4) or
            (lookup[offset + green].toInt() shl 2) or lookup[offset + blue].toInt()]
    }
}

/** Formats 1/4 preserve indexed RLE storage; 2/3 preserve packed pixel storage. */
internal object WatchTileEncoder {
    private val compressor by lazy { LZ4Factory.safeInstance().fastCompressor() }

    fun encode(indexes: ByteArray, width: Int, height: Int): EncodedWatchTile {
        require(width > 0 && height > 0 && width % 2 == 0 && indexes.size == width * height)
        val packed = pack(indexes)
        val rle = rle(indexes)
        val indexBytes = height * ((width + 31) / 32) * 3
        val candidates = if (rle.size + indexBytes < packed.size) {
            listOf(EncodedWatchTile(width, height, TILE_COMPRESSION_RLE, rle), EncodedWatchTile(width, height, TILE_COMPRESSION_LZ4_RLE, compress(rle)))
        } else {
            listOf(EncodedWatchTile(width, height, TILE_COMPRESSION_PACKED, packed), EncodedWatchTile(width, height, TILE_COMPRESSION_RLE, rle), EncodedWatchTile(width, height, TILE_COMPRESSION_LZ4_PACKED, compress(packed)))
        }
        return candidates.minBy { it.payload.size }
    }

    internal fun pack(indexes: ByteArray): ByteArray = ByteArray((indexes.size + 1) / 2) { offset ->
        val first = indexes[offset * 2].toInt() and 15
        val second = if (offset * 2 + 1 < indexes.size) indexes[offset * 2 + 1].toInt() and 15 else 0
        (first or (second shl 4)).toByte()
    }

    internal fun rle(indexes: ByteArray): ByteArray {
        val output = ByteArray(indexes.size)
        var read = 0
        var written = 0
        while (read < indexes.size) {
            val index = indexes[read].toInt() and 15
            var length = 1
            while (length < 16 && read + length < indexes.size && indexes[read + length] == indexes[read]) length++
            output[written++] = (((length - 1) shl 4) or index).toByte()
            read += length
        }
        return output.copyOf(written)
    }

    internal fun compress(bytes: ByteArray): ByteArray = compressor.compress(bytes)
}
