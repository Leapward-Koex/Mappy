package com.leapwardkoex.mappy

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.ByteArrayOutputStream
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.ceil
import kotlin.math.pow
import kotlin.math.roundToInt
import androidx.test.platform.app.InstrumentationRegistry
import net.jpountz.lz4.LZ4Factory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Offline device tests: real Android bitmap decode, synthetic imagery, no credentials/network. */
@RunWith(AndroidJUnit4::class)
class TilePipelineInstrumentedTest {
    @Test fun realBitmapBulkReadAndBoundaryCropsPreservePixels() {
        for (dimension in listOf(256, 512, 1024)) {
            val colors = IntArray(dimension * dimension) { color(it % dimension, it / dimension) }
            val png = imageBytes(dimension, colors)
            val raster = requireNotNull(AndroidSourceTileDecoder().decode(png))
            assertArrayEquals(colors, raster.readPixels())
            raster.recycle()
            val provider = provider(png, dimension)
            try {
                for (source in listOf("roadmap", "satellite", "hybrid", "terrain")) for ((width, height) in listOf(54 to 63, 72 to 84, 108 to 126)) {
                    provider.setMapTileSettings(GoogleMapTilesProvider.MapTileSettings(mapSource = source, watchTileWidth = width, watchTileHeight = height))
                    for (worldX in listOf(250, (1 shl 16) * 256 - 20)) {
                        val tile = provider.watchTile(worldX, 250, 16)
                        assertEquals(true, tile["ok"])
                        val indexes = decode(tile, width, height)
                        for (y in 0 until height) for (x in 0 until width) {
                            val sx = ((worldX + x) % 256) * dimension / 256
                            val sy = ((250 + y) % 256) * dimension / 256
                            assertEquals(DayTileColors.paletteIndex(color(sx, sy)), indexes[y * width + x].toInt())
                        }
                    }
                }
            } finally { provider.close() }
        }
    }

    @Test fun reportsOfflineColdWarmSourceAndEncodedCacheTimings() {
        val dimension = 256
        val png = imageBytes(dimension, IntArray(dimension * dimension) { color(it % dimension, it / dimension) })
        val gets = AtomicInteger()
        val provider = provider(png, dimension, gets)
        try {
            for (source in listOf("roadmap", "satellite", "hybrid", "terrain")) for ((width, height) in listOf(54 to 63, 72 to 84, 108 to 126)) {
                provider.setMapTileSettings(GoogleMapTilesProvider.MapTileSettings(mapSource = source, watchTileWidth = width, watchTileHeight = height))
                provider.watchTile(250, 250, 16) // warm code/LUT before timed samples
                for (mode in listOf("cold", "warmSource", "encoded")) {
                    provider.clearProviderSessions()
                    if (mode != "cold") provider.watchTile(250, 250, 16)
                    val initialGets = gets.get()
                    val samples = ArrayList<Map<*, *>>()
                    var peakJavaHeap = 0L
                    var peakNativeHeap = 0L
                    for (iteration in 0 until 30) {
                        if (mode == "cold") provider.clearProviderSessions()
                        val x = if (mode == "warmSource") 240 + iteration else 250
                        val result = provider.watchTile(x, 250, 16)
                        assertEquals(true, result["ok"])
                        samples.add(result["preparation_metrics"] as Map<*, *>)
                        val runtime = Runtime.getRuntime()
                        peakJavaHeap = maxOf(peakJavaHeap, runtime.totalMemory() - runtime.freeMemory())
                        peakNativeHeap = maxOf(peakNativeHeap, android.os.Debug.getNativeHeapAllocatedSize())
                    }
                    if (mode != "cold") assertEquals("Source cache should avoid all new downloads", initialGets, gets.get())
                    Log.i("MappyTileBench", "offline source=$source size=${width}x${height} cache=$mode sampledPeakJavaHeapBytes=$peakJavaHeap sampledPeakNativeHeapBytes=$peakNativeHeap retries=0")
                    for (stage in listOf("preparationMillis", "sourceWaitMillis", "fetchMillis", "decodeMillis", "cropMillis", "colorMillis", "encodeMillis")) {
                        val values = samples.map { (it[stage] as? Number)?.toDouble() ?: 0.0 }.sorted()
                        Log.i("MappyTileBench", "offline source=$source size=${width}x${height} cache=$mode stage=$stage median=${values[14]} p95=${values[ceil(values.size * 0.95).toInt() - 1]}")
                    }
                }
            }
        } finally { provider.close() }
    }

    @Test fun reportsLegacyVersusLookupColorTiming() {
        val random = java.util.Random(5284)
        val colors = IntArray(54 * 63 * 64) { random.nextInt(0x1000000) }
        var checksum = 0L
        repeat(3) { for (color in colors) { checksum += legacyColor(color); checksum += DayTileColors.paletteIndex(color) } }
        fun measure(block: () -> Unit): Double {
            val start = System.nanoTime()
            block()
            return (System.nanoTime() - start) / 1_000_000.0
        }
        val old = ArrayList<Double>()
        val optimized = ArrayList<Double>()
        repeat(30) {
            old.add(measure { for (color in colors) checksum += legacyColor(color) })
            optimized.add(measure { for (color in colors) checksum += DayTileColors.paletteIndex(color) })
        }
        old.sort(); optimized.sort()
        Log.i("MappyTileBench", "colorComparison colors=${colors.size} samples=30 legacyMedian=${old[14]} legacyP95=${old[28]} lookupMedian=${optimized[14]} lookupP95=${optimized[28]} speedup=${old[14] / optimized[14]}")
        assertTrue(checksum > 0)
    }

    @Test fun obsoleteNightPreferenceCannotChangeOtherSettingsOrDayPixels() {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        // Keep this preference probe isolated even when tests run against a regular app ID.
        val isolated = object : android.content.ContextWrapper(target) {
            override fun getSharedPreferences(name: String, mode: Int): android.content.SharedPreferences =
                super.getSharedPreferences("tile-pipeline-preference-test-$name", mode)
        }
        val preferences = isolated.getSharedPreferences(DISPLAY_SETTINGS_PREFERENCES_NAME, Context.MODE_PRIVATE)
        try {
            preferences.edit().clear().putInt("themeMode", 2).putInt(UNITS_MODE_SETTING, 1)
                .putInt(HAPTIC_MODE_SETTING, 2).putInt(MAP_ORIENTATION_SETTING, 1).commit()
            val dayPixel = DayTileColors.paletteIndex(0x406080)
            val settings = loadNativeDisplaySettings(isolated)
            assertEquals(1, settings.unitsMode); assertEquals(2, settings.hapticMode)
            assertEquals(1, settings.mapOrientation)
            saveNativeDisplaySettings(isolated, settings)
            assertFalse(displaySettingsMap(settings).containsKey("themeMode"))
            assertEquals(dayPixel, DayTileColors.paletteIndex(0x406080))
            assertEquals(2, preferences.getInt("themeMode", -1))
            assertEquals(settings, loadNativeDisplaySettings(isolated))
        } finally { preferences.edit().clear().commit() }
    }

    private fun legacyColor(color: Int): Int {
        val red = (((color ushr 16) and 255).toDouble() - 10.0).coerceIn(0.0, 255.0)
        val green = (((color ushr 8) and 255).toDouble() - 10.0).coerceIn(0.0, 255.0)
        val blue = ((color and 255).toDouble() - 10.0).coerceIn(0.0, 255.0)
        val average = (red + green + blue) / 3.0
        fun channel(value: Double): Int {
            val saturated = (average + (value - average) * 3.0).coerceIn(0.0, 255.0)
            return ((((saturated / 255.0).pow(1.8) * 255.0).roundToInt() + 42) / 85).coerceIn(0, 3)
        }
        val pebble = (channel(red) shl 4) or (channel(green) shl 2) or channel(blue)
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

    private fun decode(tile: Map<String, Any?>, width: Int, height: Int): ByteArray {
        val encoded = tile["chunk_data"] as ByteArray
        val format = (tile["compression_format"] as Number).toInt()
        val packedSize = width * height / 2
        val bytes = when (format) {
            3 -> LZ4Factory.safeInstance().safeDecompressor().decompress(encoded, packedSize)
            4 -> LZ4Factory.safeInstance().safeDecompressor().decompress(encoded, packedSize - height * ((width + 31) / 32) * 3 - 1)
            else -> encoded
        }
        val result = ByteArray(width * height)
        if (format == 1 || format == 4) {
            var position = 0
            bytes.forEach { value -> repeat(((value.toInt() and 255) ushr 4) + 1) { result[position++] = (value.toInt() and 15).toByte() } }
            assertEquals(result.size, position)
        } else result.indices.forEach { result[it] = ((bytes[it / 2].toInt() ushr ((it and 1) * 4)) and 15).toByte() }
        return result
    }

    private fun color(x: Int, y: Int): Int = (0xff shl 24) or (((x * 7 + y * 3) and 255) shl 16) or
        (((y * 5 + x) and 255) shl 8) or ((x xor y) and 255)

    private fun imageBytes(dimension: Int, colors: IntArray): ByteArray {
        val bitmap = Bitmap.createBitmap(colors, dimension, dimension, Bitmap.Config.ARGB_8888)
        return try { ByteArrayOutputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it); it.toByteArray() } }
        finally { bitmap.recycle() }
    }

    private fun provider(png: ByteArray, dimension: Int, gets: AtomicInteger = AtomicInteger()): GoogleMapTilesProvider =
        GoogleMapTilesProvider(FixtureCredentials(), object : AndroidIdentityProvider {
            override fun currentIdentity() = AndroidIdentity("test.mappy", "0".repeat(40))
        }, object : GoogleHttpClient {
            override fun execute(request: GoogleHttpRequest): GoogleHttpResponse {
                if (request.url.contains("createSession")) {
                    val json = "{\"tileWidth\":$dimension,\"tileHeight\":$dimension,\"session\":\"offline-session\"}"
                    return GoogleHttpResponse(200, json, json.toByteArray())
                }
                check(request.url.contains("2dtiles"))
                gets.incrementAndGet()
                return GoogleHttpResponse(200, "", png)
            }
        })

    private class FixtureCredentials : GoogleCredentialStore {
        override fun getPlaintextKey() = "offline-test-key"
        override fun getStatus(): Map<String, Any?> = mapOf("configured" to true, "validationState" to ApiKeyStore.STATE_VALID)
        override fun storeApiKey(plaintext: String) = getStatus()
        override fun clearApiKey() = getStatus()
        override fun clearValidationStatus() = getStatus()
        override fun markValidationResult(validationState: String, validationDetail: String?, httpStatus: Int?, packageName: String, certSha1: String) = getStatus()
    }
}
