package com.leapwardkoex.mappy

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dalvik.system.DexClassLoader
import java.io.File
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/** Loads the actual release APK with no debug app classes in its parent loader. */
@RunWith(AndroidJUnit4::class)
class MinifiedTileCodecInstrumentedTest {
    @Test fun releaseApkRetainsSafeFactoryAndReconstructsPackedPixels() {
        val arguments = InstrumentationRegistry.getArguments()
        val releasePath = arguments.getString("releaseApk")
        assumeTrue("Pass -e releaseApk <readable APK path> for release verification", releasePath != null)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val local = File(context.codeCacheDir, "tile-codec-release.apk")
        try {
            if (local.exists()) { local.setWritable(true); check(local.delete()) }
            File(requireNotNull(releasePath)).inputStream().use { input ->
                local.outputStream().use { output -> input.copyTo(output) }
            }
            check(local.setReadOnly()) // Android requires dynamically loaded code to be immutable.
            val loader = DexClassLoader(local.path, context.codeCacheDir.path, null,
                ClassLoader.getSystemClassLoader().parent)
            val factoryClass = loader.loadClass("net.jpountz.lz4.LZ4Factory")
            assertSame(loader, factoryClass.classLoader)
            val factory = factoryClass.getMethod("safeInstance").invoke(null)
            val compressor = factoryClass.getMethod("fastCompressor").invoke(factory)
            assertEquals("net.jpountz.lz4.LZ4JavaSafeCompressor", compressor.javaClass.name)
            val decompressor = factoryClass.getMethod("safeDecompressor").invoke(factory)
            val compress = compressor.javaClass.getDeclaredMethod("compress", ByteArray::class.java,
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, ByteArray::class.java,
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).apply { isAccessible = true }
            val decompress = decompressor.javaClass.getDeclaredMethod("decompress", ByteArray::class.java,
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType, ByteArray::class.java,
                Int::class.javaPrimitiveType, Int::class.javaPrimitiveType).apply { isAccessible = true }
            for (length in listOf(1701, 3024, 6804)) {
                val input = ByteArray(length) { (it % 7).toByte() }
                val compressed = ByteArray(length + length / 255 + 16)
                val encodedSize = compress.invoke(compressor, input, 0, length, compressed, 0, compressed.size) as Int
                assertTrue(encodedSize < length)
                val output = ByteArray(length)
                val decodedSize = decompress.invoke(decompressor, compressed, 0, encodedSize, output, 0, length) as Int
                assertEquals(length, decodedSize)
                assertArrayEquals(input, output)
            }
        } finally {
            local.setWritable(true)
            local.delete()
        }
    }
}
