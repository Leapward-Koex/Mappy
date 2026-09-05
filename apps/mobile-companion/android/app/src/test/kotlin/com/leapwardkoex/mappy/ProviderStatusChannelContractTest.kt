package com.leapwardkoex.mappy

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ProviderStatusChannelContractTest {
    @Test
    fun providerStatusReadDoesNotEmitAnotherProviderOrBridgeEvent() {
        val source = sourceFile("src/main/kotlin/com/leapwardkoex/mappy/MainActivity.kt")
        val handler = source
            .substringAfter("\"getProviderStatus\" ->")
            .substringBefore("\"getMapTileSettings\" ->")

        assertEquals(
            "result.success(mapTilesProvider.providerStatus())",
            handler.trim()
        )
    }

    private fun sourceFile(relativePath: String): String {
        val candidates = listOf(File("app/$relativePath"), File(relativePath))
        val file = candidates.firstOrNull(File::isFile)
        assertTrue(file != null, "$relativePath was not found from the unit test working directory.")
        return file.readText()
    }
}
