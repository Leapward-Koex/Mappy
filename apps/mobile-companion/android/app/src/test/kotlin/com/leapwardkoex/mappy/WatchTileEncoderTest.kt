package com.leapwardkoex.mappy

import java.io.File
import java.util.Random
import net.jpountz.lz4.LZ4Factory
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class WatchTileEncoderTest {
    private val referencePalette = IntArray(64) { color ->
        val red = ((color ushr 4) and 3) * 85
        val green = ((color ushr 2) and 3) * 85
        val blue = (color and 3) * 85
        DayTileColors.palette.indices.minBy { index ->
            val candidate = DayTileColors.palette[index]
            val dr = red - ((candidate ushr 16) and 255)
            val dg = green - ((candidate ushr 8) and 255)
            val db = blue - (candidate and 255)
            dr * dr + dg * dg + db * db
        }
    }

    private fun legacyColor(color: Int, paletteScan: Boolean = false): Int {
        val red = (((color ushr 16) and 255).toDouble() - 10.0).coerceIn(0.0, 255.0)
        val green = (((color ushr 8) and 255).toDouble() - 10.0).coerceIn(0.0, 255.0)
        val blue = ((color and 255).toDouble() - 10.0).coerceIn(0.0, 255.0)
        val average = (red + green + blue) / 3.0
        fun channel(value: Double): Int {
            val saturated = (average + (value - average) * 3.0).coerceIn(0.0, 255.0)
            return ((((saturated / 255.0).pow(1.8) * 255.0).roundToInt() + 42) / 85).coerceIn(0, 3)
        }
        val pebble = (channel(red) shl 4) or (channel(green) shl 2) or channel(blue)
        if (!paletteScan) return referencePalette[pebble]
        val qr = ((pebble ushr 4) and 3) * 85
        val qg = ((pebble ushr 2) and 3) * 85
        val qb = (pebble and 3) * 85
        var best = 0
        var distance = Int.MAX_VALUE
        for (index in DayTileColors.palette.indices) {
            val candidate = DayTileColors.palette[index]
            val dr = qr - ((candidate ushr 16) and 255)
            val dg = qg - ((candidate ushr 8) and 255)
            val db = qb - (candidate and 255)
            val next = dr * dr + dg * dg + db * db
            if (next < distance) { best = index; distance = next }
        }
        return best
    }

    @Test fun exactLookupMatchesEveryRgbColor() {
        for (color in 0..0xFFFFFF) {
            val expected = legacyColor(color)
            val actual = DayTileColors.paletteIndex(color)
            check(expected == actual) { "Colour mismatch for RGB ${color.toString(16)}: $expected != $actual" }
        }
        assertEquals(DayTileColors.paletteIndex(0x123456), DayTileColors.paletteIndex(0x80123456.toInt()))
    }

    private fun corpus(width: Int, height: Int, kind: Int): ByteArray {
        val random = Random(9147L + kind)
        val pixels = ByteArray(width * height)
        when (kind) {
            1 -> {
                var position = 0
                var previous = -1
                while (position < pixels.size) {
                    var color = random.nextInt(16)
                    if (color == previous) color = (color + 1) and 15
                    val length = 4 + random.nextInt(13)
                    repeat(length.coerceAtMost(pixels.size - position)) { pixels[position++] = color.toByte() }
                    previous = color
                }
            }
            2 -> pixels.indices.forEach { pixels[it] = random.nextInt(16).toByte() }
            3 -> pixels.indices.forEach { pixels[it] = (it % 7).toByte() }
            4 -> pixels.fill(6)
        }
        return pixels
    }

    @Test fun sharedCodecVectorsAndAtRestSelection() {
        val root = generateSequence(File(".").absoluteFile) { it.parentFile }
            .first { File(it, "tooling").isDirectory }
        val vectors = JSONArray()
        for ((width, height) in listOf(54 to 63, 72 to 84, 108 to 126)) {
            for (kind in 1..4) {
                val pixels = corpus(width, height, kind)
                val encoded = WatchTileEncoder.encode(pixels, width, height)
                assertEquals(kind, encoded.format, "Corpus $kind at ${width}x$height")
                val packed = WatchTileEncoder.pack(pixels)
                val rle = WatchTileEncoder.rle(pixels)
                val retainedRle = rle.size + height * ((width + 31) / 32) * 3 < packed.size
                assertEquals(retainedRle, encoded.format == 1 || encoded.format == 4)
                val decoded = when (encoded.format) {
                    3, 4 -> {
                        val output = ByteArray(pixels.size)
                        val size = LZ4Factory.safeInstance().safeDecompressor().decompress(
                            encoded.payload, 0, encoded.payload.size, output, 0, output.size)
                        output.copyOf(size)
                    }
                    else -> encoded.payload
                }
                assertContentEquals(if (retainedRle) rle else packed, decoded)
                vectors.put(JSONObject().put("name", "format${kind}_${width}x$height")
                    .put("width", width).put("height", height).put("format", encoded.format)
                    .put("payload", JSONArray(encoded.payload.map { it.toInt() and 255 }))
                    .put("packed", JSONArray(packed.map { it.toInt() and 255 })))
            }
        }
        val file = File(root, "tooling/tile-codec-vectors.json")
        if (System.getenv("MAPPY_WRITE_TILE_VECTORS") == "1") file.writeText(vectors.toString() + "\n")
        assertEquals(vectors.toString(), JSONArray(file.readText()).toString())
    }

    @Test fun rawWinsTiesAndRleCrossesRows() {
        assertEquals(2, WatchTileEncoder.encode(byteArrayOf(3, 3), 2, 1).format)
        assertContentEquals(byteArrayOf(0xF2.toByte(), 0x12), WatchTileEncoder.rle(ByteArray(18) { 2 }))
        assertContentEquals(byteArrayOf(0x21, 0x43), WatchTileEncoder.pack(byteArrayOf(1, 2, 3, 4)))
    }

    @Test fun reproducibleColorAndCodecBenchmark() {
        if (System.getenv("MAPPY_TILE_BENCHMARK") != "1") return
        val random = Random(5284)
        val colors = IntArray(54 * 63 * 64) { random.nextInt(0x1000000) }
        var checksum = 0L
        repeat(3) { colors.forEach { checksum += DayTileColors.paletteIndex(it) } }
        fun measure(block: () -> Unit): Double {
            val start = System.nanoTime()
            block()
            return (System.nanoTime() - start) / 1_000_000.0
        }
        val baseline = List(7) { measure { colors.forEach { checksum += legacyColor(it, paletteScan = true) } } }.sorted()[3]
        val optimized = List(7) { measure { colors.forEach { checksum += DayTileColors.paletteIndex(it) } } }.sorted()[3]
        val report = JSONObject().put("runtime", System.getProperty("java.runtime.version"))
            .put("colors", colors.size).put("legacyColorMillis", baseline)
            .put("optimizedColorMillis", optimized).put("colorSpeedup", baseline / optimized)
            .put("checksum", checksum)
        val root = generateSequence(File(".").absoluteFile) { it.parentFile }
            .first { File(it, "tooling").isDirectory }
        report.put("savedCorpus", benchmarkSavedCorpus(root))
        val file = File(root, "artifacts/tile-performance/android-jvm-benchmark.json")
        file.parentFile?.mkdirs()
        file.writeText(report.toString(2))
        println("TILE_BENCHMARK $report")
        assertTrue(checksum > 0)
    }
    private fun legacyRle(indexes: ByteArray): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        var offset = 0
        while (offset < indexes.size) {
            val color = indexes[offset].toInt() and 15
            var run = 1
            while (offset + run < indexes.size && run < 16 && indexes[offset + run] == indexes[offset]) run++
            output.write(((run - 1) shl 4) or color)
            offset += run
        }
        return output.toByteArray()
    }

    private fun benchmarkSavedCorpus(root: File): JSONArray {
        val file = File(root, "tooling/real-map-fixtures/generated/googleplex-fixture.json")
        if (!file.isFile) return JSONArray()
        val fixture = JSONObject(file.readText())
        val tiles = fixture.getJSONObject("tiles")
        val bank = fixture.getJSONObject("bank")
        val minimumX = bank.getInt("minWorldX")
        val minimumY = bank.getInt("minWorldY")
        val atlasWidth = bank.getInt("cols") * 54
        val atlasHeight = bank.getInt("rows") * 63
        val atlas = ByteArray(atlasWidth * atlasHeight)
        val present = BooleanArray(atlas.size)
        val origins = tiles.keys().asSequence().toList().sorted().map { key ->
            val parts = key.split(":")
            val x = parts[0].toInt() - minimumX
            val y = parts[1].toInt() - minimumY
            val rle = tiles.getJSONArray(key)
            val pixels = ArrayList<Byte>(54 * 63)
            for (offset in 0 until rle.length()) {
                val value = rle.getInt(offset)
                repeat((value ushr 4) + 1) { pixels.add((value and 15).toByte()) }
            }
            check(pixels.size == 54 * 63)
            for (py in 0 until 63) for (px in 0 until 54) {
                val index = (y + py) * atlasWidth + x + px
                check(!present[index])
                atlas[index] = pixels[py * 54 + px]
                present[index] = true
            }
            x to y
        }
        check(present.all { it })
        fun elapsed(block: () -> Unit): Double {
            val start = System.nanoTime()
            block()
            return (System.nanoTime() - start) / 1_000_000.0
        }
        val groups = JSONArray()
        for ((width, height) in listOf(54 to 63, 72 to 84, 108 to 126)) {
            val crops = origins.filter { (x, y) -> x + width <= atlasWidth && y + height <= atlasHeight }
                .map { (x, y) -> ByteArray(width * height) { index ->
                    atlas[(y + index / width) * atlasWidth + x + index % width]
                } }
            val oldPayloads = crops.map { legacyRle(it) }
            val encoded = crops.map { WatchTileEncoder.encode(it, width, height) }
            repeat(3) { crops.forEach { WatchTileEncoder.encode(it, width, height) } }
            val oldMillis = List(7) { elapsed { crops.forEach { legacyRle(it) } } }.sorted()[3]
            val newMillis = List(7) { elapsed { crops.forEach { WatchTileEncoder.encode(it, width, height) } } }.sorted()[3]
            val oldBytes = oldPayloads.sumOf { it.size }
            val newBytes = encoded.sumOf { it.payload.size }
            groups.put(JSONObject()
                .put("source", "saved Googleplex Google Map Tiles palette corpus")
                .put("geometry", "${width}x$height").put("tileCount", crops.size)
                .put("recroppedFromSavedAtlas", width != 54)
                .put("legacyRleBytes", oldBytes).put("adaptiveBytes", newBytes)
                .put("byteReductionPercent", (oldBytes - newBytes) * 100.0 / oldBytes)
                .put("legacyChunks3072", oldPayloads.sumOf { (it.size + 3071) / 3072 })
                .put("adaptiveChunks3072", encoded.sumOf { (it.payload.size + 3071) / 3072 })
                .put("legacyRleEncodeMillis", oldMillis).put("adaptiveEncodeMillis", newMillis)
                .put("formats", JSONObject(encoded.groupingBy { it.format.toString() }.eachCount())))
        }
        return groups
    }

}
