package com.leapwardkoex.mappy

import java.io.File
import kotlin.test.Test
import kotlin.test.assertTrue

class AndroidPublicationComplianceTest {
    @Test
    fun androidPublicationSurfaceUsesStandaloneTerminology() {
        val sourceRoot = listOf(File("app/src"), File("src"))
            .firstOrNull { it.isDirectory }
        assertTrue(sourceRoot != null, "Android source root was not found from the unit test working directory.")
        val forbiddenTerms = listOf(
            "mirror" + "map",
            "mm" + "_",
            "recover" + "ed",
            "propriet" + "ary",
            "replace" + "ment app",
            "source" + " app"
        )
        val auditedExtensions = setOf("kt", "kts", "xml", "properties")
        val matches = sourceRoot.walkTopDown()
            .filter { file ->
                file.isFile && file.extension.lowercase() in auditedExtensions
            }
            .flatMap { file ->
                val source = file.readText().lowercase()
                forbiddenTerms.asSequence()
                    .filter { term -> source.contains(term) }
                    .map { term -> "${file.name}:$term" }
            }
            .toList()

        assertTrue(matches.isEmpty(), "Standalone-term scan found: ${matches.joinToString()}")
    }

    @Test
    fun requiredDiagnosticEventsUseOwnedSourceLabels() {
        val source = mainActivitySource()

        assertEventSource(source, "api_key_stored", "android_bridge")
        assertEventSource(source, "api_key_cleared", "android_bridge")
        assertEventSource(source, "provider_validation_started", "provider")
        assertEventSource(source, "provider_validation_finished", "provider")
        assertEventSource(source, "error_state_sent", "android_bridge")
        assertNoEventSource(source, "error_state_sent", "tile_worker")
        assertNoEventSource(source, "error_state_sent", "route_worker")
        assertNoEventSource(source, "error_state_sent", "location")
        assertNoEventSource(source, "error_state_sent", "watch")
        assertNoEventSource(source, "watch_command_received", "route_worker")
        assertNoEventSource(source, "watch_command_received", "watch")
        assertTrue(
            !source.contains("category == 0 -> \"watch_command_received\""),
            "watch CMD_LOG_EVENT records must not reuse watch_command_received."
        )
        assertTrue(
            !source.contains("source == \"watch\" -> \"watch_command_received\""),
            "watch diagnostic fallbacks must not reuse watch_command_received."
        )
        assertTrue(
            !source.contains("else -> \"error_state_sent\""),
            "watch CMD_LOG_EVENT records must not reuse error_state_sent."
        )
        assertTrue(
            source.contains("eventName = \"location_fix_updated\""),
            "Missing diagnostic event location_fix_updated."
        )
        assertTrue(
            source.contains("source: String = \"location\""),
            "location_fix_updated must default to source location."
        )
        assertTrue(
            !source.contains("location_stream"),
            "location_stream is not a diagnostics source enum value."
        )
        assertTrue(
            source.contains("clearNativeRouteCache(recordDiagnostic = true, source = \"android_bridge\")"),
            "Watch-originated route cache clears must be recorded by android_bridge."
        )
        assertTrue(
            !source.contains("clearNativeRouteCache(recordDiagnostic = true, source = \"watch\")"),
            "cache_cleared does not permit source watch."
        )
    }

    @Test
    fun tileDeliveryRetryIsOwnedByTheBackgroundRuntime() {
        val activitySource = mainActivitySource()
        val runtimeSource = sourceFile("MappyWatchRuntime.kt")
        val payloadSource = sourceFile("NativeWatchPayloads.kt")

        assertTrue(
            runtimeSource.contains("\"tileDrop\" -> tileDeliveryRetryMessage(event)?.let(bridge::enqueue)"),
            "The persistent watch runtime must retire dropped tile requests even without an Activity."
        )
        assertTrue(
            !activitySource.contains("enqueueTileRetryMessage") &&
                !activitySource.contains("watchBridge?.enqueue"),
            "Activity attachment must not own tile-drop retries."
        )
        assertTrue(
            payloadSource.contains("event[KEY_REQUEST_ID]") &&
                payloadSource.contains("KEY_REQUEST_ID to requestId"),
            "Runtime-owned tile retries must preserve the positive logical request ID."
        )
    }

    private fun assertNoEventSource(source: String, eventName: String, rejectedSource: String) {
        var searchStart = 0
        while (true) {
            val eventIndex = source.indexOf("eventName = \"$eventName\"", searchStart)
            if (eventIndex < 0) {
                return
            }
            val start = (eventIndex - 400).coerceAtLeast(0)
            val end = (eventIndex + 220).coerceAtMost(source.length)
            val window = source.substring(start, end)
            assertTrue(
                !window.contains("source = \"$rejectedSource\""),
                "$eventName must not use source $rejectedSource."
            )
            searchStart = eventIndex + eventName.length
        }
    }

    private fun assertEventSource(source: String, eventName: String, expectedSource: String) {
        val eventIndex = source.indexOf("eventName = \"$eventName\"")
        assertTrue(eventIndex >= 0, "Missing diagnostic event $eventName.")
        val start = (eventIndex - 400).coerceAtLeast(0)
        val end = (eventIndex + 220).coerceAtMost(source.length)
        val window = source.substring(start, end)
        assertTrue(
            window.contains("source = \"$expectedSource\""),
            "$eventName must use source $expectedSource."
        )
    }

    private fun mainActivitySource(): String {
        return sourceFile("MainActivity.kt")
    }

    private fun sourceFile(name: String): String {
        val candidates = listOf(
            File("app/src/main/kotlin/com/leapwardkoex/mappy/$name"),
            File("src/main/kotlin/com/leapwardkoex/mappy/$name")
        )
        val file = candidates.firstOrNull { it.isFile }
        assertTrue(file != null, "$name was not found from the unit test working directory.")
        return file.readText()
    }
}
