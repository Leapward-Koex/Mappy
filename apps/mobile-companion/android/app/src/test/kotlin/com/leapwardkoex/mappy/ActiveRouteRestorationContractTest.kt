package com.leapwardkoex.mappy

import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ActiveRouteRestorationContractTest {
    @Test
    fun channelSnapshotPreservesEveryPersistedRouteField() {
        val route = PersistedActiveRouteRequest(
            requestId = 42,
            originPolicy = ROUTE_ORIGIN_EXPLICIT_PLACE,
            origin = NativeRouteEndpoint(
                label = "Britomart",
                address = "8-10 Queen Street, Auckland",
                latitude = -36.8441,
                longitude = 174.7678,
                placeId = "origin-place"
            ),
            destination = NativeRouteEndpoint(
                label = "Auckland Museum",
                address = "The Auckland Domain, Parnell",
                latitude = -36.8602,
                longitude = 174.7778,
                placeId = "destination-place"
            ),
            travelMode = 1,
            savedSlot = 3,
            updatedAtMillis = 1_770_000_000_000
        )

        val payload = route.toChannelMap()
        assertEquals(42, payload["requestId"])
        assertEquals(ROUTE_ORIGIN_EXPLICIT_PLACE, payload["originPolicy"])
        assertEquals(1, payload["travelMode"])
        assertEquals(3, payload["savedSlot"])
        assertEquals(1_770_000_000_000, payload["updatedAtMillis"])
        assertEquals("Britomart", (payload["origin"] as Map<*, *>)["label"])
        assertEquals("origin-place", (payload["origin"] as Map<*, *>)["placeId"])
        assertEquals("Auckland Museum", (payload["destination"] as Map<*, *>)["label"])
        assertEquals("destination-place", (payload["destination"] as Map<*, *>)["placeId"])
    }

    @Test
    fun persistenceDecoderAcceptsFreshRoutesAndRejectsStaleOrCorruptRecords() {
        val updatedAt = 1_000_000L
        val valid = """
            {
              "schemaVersion": 1,
              "requestId": 42,
              "originPolicy": "current_location",
              "travelMode": 2,
              "savedSlot": null,
              "updatedAtMillis": $updatedAt,
              "destination": {
                "label": "Auckland Museum",
                "address": "The Auckland Domain, Parnell",
                "latitude": -36.8602,
                "longitude": 174.7778,
                "placeId": null
              }
            }
        """.trimIndent()

        val decoded = NativeActiveRoutePersistence.decode(valid, updatedAt + 1)
        assertEquals(42, decoded?.requestId)
        assertEquals("Auckland Museum", decoded?.destination?.label)
        assertEquals(
            42,
            NativeActiveRoutePersistence.decode(
                valid,
                updatedAt + ACTIVE_ROUTE_TTL_MILLIS
            )?.requestId,
            "A route remains valid at the exact TTL boundary."
        )
        assertNull(
            NativeActiveRoutePersistence.decode(
                valid,
                updatedAt + ACTIVE_ROUTE_TTL_MILLIS + 1
            )
        )
        assertNull(NativeActiveRoutePersistence.decode("not json", updatedAt + 1))
        assertNull(
            NativeActiveRoutePersistence.decode(
                valid.replace("\"requestId\": 42", "\"requestId\": 0"),
                updatedAt + 1
            )
        )
        assertNull(
            NativeActiveRoutePersistence.decode(
                valid.replace("\"current_location\"", "\"explicit_place\""),
                updatedAt + 1
            )
        )
        assertNull(
            NativeActiveRoutePersistence.decode(
                valid,
                updatedAt - (5 * 60 * 1000L) - 1
            ),
            "A route timestamp too far in the future is corrupt."
        )
        assertNull(
            NativeActiveRoutePersistence.decode(
                valid.replace("\"travelMode\": 2", "\"travelMode\": 99"),
                updatedAt + 1
            )
        )
        assertNull(
            NativeActiveRoutePersistence.decode(
                valid.replace("\"savedSlot\": null", "\"savedSlot\": 999"),
                updatedAt + 1
            )
        )
        assertNull(
            NativeActiveRoutePersistence.decode(
                valid.replace("\"travelMode\": 2", "\"travelMode\": \"2\""),
                updatedAt + 1
            ),
            "Persistence must not coerce malformed field types."
        )
    }

    @Test
    fun rerouteAndSnapshotReadsUseTheTtlCheckedPersistenceRecord() {
        val source = sourceFile("MappyWatchCommandDispatcher.kt")
        val reserveReroute = functionBody(source, "fun reserveActiveRouteOperation")
        val current = functionBody(source, "fun currentActiveRoute")
        val authoritativeRead = functionBody(source, "private fun readAuthoritativeActiveRequest")

        assertTrue(source.contains("rerouteActiveRoute(reserveActiveRouteOperation())"))
        assertTrue(reserveReroute.contains("readAuthoritativeActiveRequest()"))
        assertTrue(current.contains("readAuthoritativeActiveRequest()?.toChannelMap()"))
        assertTrue(authoritativeRead.contains("NativeActiveRoutePersistence.read(appContext)"))
        assertTrue(authoritativeRead.contains("reconcileActiveRouteLocked(persisted)"))
    }

    @Test
    fun routeChangedEventsFollowSynchronousPersistenceCommits() {
        val dispatcher = sourceFile("MappyWatchCommandDispatcher.kt")
        val persistence = sourceFile("NativeActiveRoutePersistence.kt")
        val compute = functionBody(dispatcher, "private fun computeRoute")
        val clear = functionBody(dispatcher, "fun clearActiveRoute")
        val write = functionBody(persistence, "fun write")
        val clearPersistence = functionBody(persistence, "fun clear")

        val persisted = compute.indexOf("NativeActiveRoutePersistence.write(appContext, updatedRequest)")
        val setEvent = compute.indexOf("emitActiveRouteChanged(updatedRequest)")
        assertTrue(persisted >= 0 && setEvent > persisted)

        val cleared = clear.indexOf("NativeActiveRoutePersistence.clear(appContext)")
        val cacheCleared = clear.indexOf("clearCachedActiveRouteLocked()")
        val clearEvent = clear.indexOf("emitActiveRouteChanged(null)")
        assertTrue(cleared >= 0 && cacheCleared > cleared && clearEvent > cacheCleared)
        assertTrue(write.contains(".commit()"), "The route write must complete before its event is emitted.")
        assertTrue(
            clearPersistence.contains("return context.getSharedPreferences") &&
                clearPersistence.contains(".commit()"),
            "A route clear must return the synchronous persistence commit result."
        )
    }

    @Test
    fun routeOperationsReserveOrderingBeforeBlockingWorkAndGateEveryMutation() {
        val source = sourceFile("MappyWatchCommandDispatcher.kt")
        val runtime = sourceFile("MappyWatchRuntime.kt")
        val compute = functionBody(source, "private fun computeRoute")
        val recovery = functionBody(source, "private fun scheduleRouteRecovery")
        val operationClear = functionBody(source, "private fun clearActiveRouteForOperation")
        val phoneStart = functionBody(runtime, "fun startNavigation")
        val phoneReroute = functionBody(runtime, "fun rerouteActiveRoute")

        val reserve = compute.indexOf("reservedGeneration ?: reserveRouteOperation(request)")
        val locationWait = compute.indexOf("WatchLocationStreamer.awaitCurrentLocation")
        val providerCall = compute.indexOf("mapTilesProvider.computeRoute")
        assertTrue(reserve >= 0 && reserve < locationWait && reserve < providerCall)
        assertTrue(compute.contains("clearActiveRouteForOperation(generation)"))
        assertTrue(compute.contains("isRouteOperationCurrentLocked(generation)"))
        assertTrue(operationClear.contains("isRouteOperationCurrentLocked(generation)"))
        assertTrue(operationClear.contains("NativeActiveRoutePersistence.clear(appContext)"))

        val recoveryReserve = recovery.indexOf("reserveRouteOperationLocked")
        val recoveryLaunch = recovery.indexOf("scope.launch")
        assertTrue(
            recoveryReserve >= 0 && recoveryReserve < recoveryLaunch,
            "Recovery must be invalidatable even if cancellation happens before its coroutine starts."
        )

        assertTrue(
            phoneStart.indexOf("dispatcher.reservePhoneRouteOperation()") <
                phoneStart.indexOf("launchTracked"),
            "Phone route ordering must be reserved synchronously in API invocation order."
        )
        assertTrue(
            phoneReroute.indexOf("dispatcher.reserveActiveRouteOperation()") <
                phoneReroute.indexOf("launchTracked"),
            "Phone reroute ordering must be reserved synchronously in API invocation order."
        )
    }

    @Test
    fun savedDestinationChangesInvalidateMatchingInFlightRouteWork() {
        val source = sourceFile("MappyWatchCommandDispatcher.kt")
        val setDestination = functionBody(source, "fun setDestination")
        val setDestinations = functionBody(source, "fun setDestinations")
        val invalidation = functionBody(source, "private fun invalidateSavedRouteOperationLocked")

        assertTrue(setDestination.contains("invalidateSavedRouteOperationLocked(update.slot)"))
        assertTrue(setDestinations.contains("invalidateSavedRouteOperationLocked()"))
        assertTrue(invalidation.contains("operation.savedSlot"))
        assertTrue(invalidation.contains("invalidateRouteOperationLocked()"))
    }

    @Test
    fun incomingShareKeepsTheExistingRouteUntilReplacementIsConfirmed() {
        val share = functionBody(sourceFile("MainActivity.kt"), "private fun startSharedGoogleMapsRoute")

        assertTrue(!share.contains("clearNativeRouteCache"))
        assertTrue(!share.contains("watchRuntime.clearActiveRoute"))
        assertTrue(share.contains("watchRuntime.startNavigation(request)"))
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

    private fun functionBody(source: String, signature: String): String {
        val signatureStart = source.indexOf(signature)
        assertTrue(signatureStart >= 0, "Missing function $signature.")
        val bodyStart = source.indexOf('{', signatureStart)
        assertTrue(bodyStart >= 0, "Missing body for $signature.")
        var depth = 0
        for (index in bodyStart until source.length) {
            when (source[index]) {
                '{' -> depth++
                '}' -> {
                    depth--
                    if (depth == 0) return source.substring(bodyStart + 1, index)
                }
            }
        }
        error("Unterminated body for $signature.")
    }
}
