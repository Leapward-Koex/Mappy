package com.leapwardkoex.mappy

import android.content.Context
import android.os.SystemClock
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

internal data class NativeRouteCalculation(
    val requestId: Int,
    val messages: List<Map<String, Any?>>,
    val successful: Boolean,
    val errorCategory: Int? = null,
    val detail: String? = null
)

internal class MappyWatchCommandDispatcher(
    context: Context,
    val apiKeyStore: ApiKeyStore,
    val mapTilesProvider: GoogleMapTilesProvider,
    private val scope: CoroutineScope,
    private val enqueueLater: (List<Map<String, Any?>>) -> Unit,
    private val eventSink: (Map<String, Any?>) -> Unit = {}
) {
    private val appContext = context.applicationContext
    private val lock = Any()
    private val nextRequestId = AtomicInteger(
        (SystemClock.elapsedRealtime() and 0x7fffffff).toInt().coerceAtLeast(1)
    )
    private val destinations = mutableListOf<NativeDestination>()
    private var settings = loadNativeDisplaySettings(appContext)
    private var routePoints: List<Map<*, *>> = emptyList()
    private var fullRoutePoints: List<Map<*, *>> = emptyList()
    private var routeSteps: List<Map<*, *>> = emptyList()
    private var routeGeneration = 0
    private var activeRequest: PersistedActiveRouteRequest? = NativeActiveRoutePersistence.read(appContext)
    private var recoveryJob: Job? = null
    private var mapSettingsGeneration = 0
    private var displaySettingsGeneration = 0

    init {
        destinations.addAll(readPersistedNativeDestinations(appContext).orEmpty())
        destinations.sortBy { it.slot }
    }

    fun dispatch(message: Map<*, *>): List<Map<String, Any?>> =
        when (intValue(message, KEY_CMD)) {
            CMD_INIT -> handleInit(message)
            CMD_TILE_REQUEST -> handleTileRequest(message)
            CMD_ROUTE_REQUEST -> handleRouteRequest(message)
            CMD_ROUTE_WINDOW_REQUEST -> handleRouteWindowRequest(message)
            CMD_NAV_STEPS -> handleNavSteps(message)
            CMD_ROUTE_CLEAR -> clearRouteMessages()
            CMD_ROUTE_APPLIED -> emptyList()
            CMD_ROUTE_COMPLETE -> {
                val requestId = intValue(message, KEY_REQUEST_ID)
                if (requestId != null) clearActiveRoute(requestId)
                emptyList()
            }
            CMD_THEME -> updateScalarSetting(CMD_THEME, intValue(message, KEY_BUTTON_ID))
            CMD_TRAVEL_MODE -> updateScalarSetting(CMD_TRAVEL_MODE, intValue(message, KEY_BUTTON_ID))
            CMD_UNITS -> updateScalarSetting(CMD_UNITS, intValue(message, KEY_BUTTON_ID))
            CMD_BACKLIGHT -> updateScalarSetting(CMD_BACKLIGHT, intValue(message, KEY_BUTTON_ID))
            CMD_MAP_ORIENTATION -> updateScalarSetting(CMD_MAP_ORIENTATION, intValue(message, KEY_BUTTON_ID))
            CMD_TILE_ANIMATION -> updateScalarSetting(CMD_TILE_ANIMATION, intValue(message, KEY_BUTTON_ID))
            CMD_BUTTON, CMD_LOG_EVENT -> emptyList()
            else -> listOf(errorMessage(ERROR_ROUTE_PROVIDER, intValue(message, KEY_CMD) ?: 0, "Unsupported watch command."))
        }

    fun startNavigation(request: Map<*, *>): NativeRouteCalculation {
        val destination = (request["destination"] as? Map<*, *>)?.let(::parseNativeRouteEndpoint)
            ?: return failure(ERROR_DESTINATION_NOT_CONFIGURED, "Destination is missing or invalid.")
        val originPolicy = if (stringValue(request, "originPolicy") == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            ROUTE_ORIGIN_EXPLICIT_PLACE
        } else {
            ROUTE_ORIGIN_CURRENT_LOCATION
        }
        val origin = if (originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            (request["origin"] as? Map<*, *>)?.let(::parseNativeRouteEndpoint)
                ?: return failure(ERROR_DESTINATION_NOT_CONFIGURED, "Route origin is missing or invalid.")
        } else null
        val routeRequest = PersistedActiveRouteRequest(
            requestId = allocateRequestId(),
            originPolicy = originPolicy,
            origin = origin,
            destination = destination,
            travelMode = travelProtocolValue(intValue(request, "travelMode") ?: settings.travelMode),
            savedSlot = null,
            updatedAtMillis = System.currentTimeMillis()
        )
        return computeRoute(routeRequest, persistOnSuccess = true)
    }

    fun rerouteActiveRoute(): NativeRouteCalculation {
        val request = synchronized(lock) { activeRequest } ?: NativeActiveRoutePersistence.read(appContext)
            ?: return failure(ERROR_DESTINATION_NOT_CONFIGURED, "No active route target.")
        return computeRoute(request.copy(updatedAtMillis = System.currentTimeMillis()), persistOnSuccess = true)
    }

    fun clearRouteMessages(): List<Map<String, Any?>> {
        clearActiveRoute()
        return listOf(watchMessage(CMD_ROUTE_CLEAR))
    }

    fun clearActiveRoute(requestId: Int? = null): Boolean {
        synchronized(lock) {
            if (requestId != null && activeRequest?.requestId != null && activeRequest?.requestId != requestId) {
                return false
            }
            routeGeneration++
            routePoints = emptyList()
            fullRoutePoints = emptyList()
            routeSteps = emptyList()
            activeRequest = null
        }
        return NativeActiveRoutePersistence.clear(appContext, requestId)
    }

    fun setDestination(raw: Map<*, *>): List<Map<String, Any?>> {
        val update = parseNativeDestinationPayload(raw) { category, command, text, offset ->
            errorMessage(category, command, text, offset)
        }
        update.error?.let { return listOf(it) }
        synchronized(lock) {
            destinations.removeAll { it.slot == update.slot }
            update.destination?.let { destinations.add(it) }
            destinations.sortBy { it.slot }
            persistNativeDestinations(appContext, destinations)
            if (activeRequest?.savedSlot == update.slot) clearActiveRoute()
        }
        return listOf(destinationsMessage())
    }

    fun setDestinations(raw: List<*>): List<Map<String, Any?>> {
        if (raw.size > MAX_DESTINATION_RECORDS) {
            return listOf(errorMessage(ERROR_DESTINATION_NOT_CONFIGURED, CMD_DESTINATIONS, "Too many destinations."))
        }
        val parsed = mutableListOf<NativeDestination>()
        val seen = mutableSetOf<Int>()
        raw.forEach { value ->
            val map = value as? Map<*, *> ?: return listOf(errorMessage(ERROR_DESTINATION_NOT_CONFIGURED, CMD_DESTINATIONS, "Invalid destination."))
            val update = parseNativeDestinationPayload(map) { category, command, text, offset ->
                errorMessage(category, command, text, offset)
            }
            update.error?.let { return listOf(it) }
            if (!seen.add(update.slot)) return listOf(errorMessage(ERROR_DESTINATION_NOT_CONFIGURED, CMD_DESTINATIONS, "Duplicate destination.", update.slot))
            update.destination?.let(parsed::add)
        }
        synchronized(lock) {
            destinations.clear()
            destinations.addAll(parsed.sortedBy { it.slot })
            persistNativeDestinations(appContext, destinations)
            if (activeRequest?.savedSlot != null) clearActiveRoute()
        }
        return listOf(destinationsMessage())
    }

    fun exportDestinations(): List<Map<String, Any?>> =
        synchronized(lock) { destinations.map(::nativeDestinationMap) }

    fun displaySettings(): Map<String, Any?> = synchronized(lock) { displaySettingsMap(settings) }

    fun setSettings(raw: Map<*, *>): List<Map<String, Any?>> {
        val messages = mutableListOf<Map<String, Any?>>()
        synchronized(lock) {
            var next = settings
            intValue(raw, THEME_MODE_SETTING)?.let { next = next.copy(themeMode = themeProtocolValue(it)); messages.add(themeMessage(next)) }
            intValue(raw, TRAVEL_MODE_SETTING)?.let { next = next.copy(travelMode = travelProtocolValue(it)); messages.add(travelModeMessage(next)) }
            intValue(raw, UNITS_MODE_SETTING)?.let { next = next.copy(unitsMode = unitsProtocolValue(it)); messages.add(unitsMessage(next)) }
            intValue(raw, BACKLIGHT_MODE_SETTING)?.let { next = next.copy(backlightMode = backlightProtocolValue(it)); messages.add(backlightMessage(next)) }
            intValue(raw, MAP_ORIENTATION_SETTING)?.let { next = next.copy(mapOrientation = mapOrientationProtocolValue(it)); messages.add(mapOrientationMessage(next)) }
            intValue(raw, TILE_ANIMATION_MODE_SETTING)?.let { next = next.copy(tileAnimationMode = tileAnimationProtocolValue(it)); messages.add(tileAnimationMessage(next)) }
            settings = next
            saveNativeDisplaySettings(appContext, settings)
        }
        return messages
    }

    fun mapSettingsMessage(reason: Int): Map<String, Any?> =
        mapTilesProvider.currentMapTileSettings().let { tileSettings ->
            watchMessage(CMD_MAP_SETTINGS, mapOf(
                KEY_BUTTON_ID to reason,
                KEY_WIDTH to tileSettings.watchTileWidth,
                KEY_HEIGHT to tileSettings.watchTileHeight,
                KEY_TOTAL_BYTES to synchronized(lock) { ++mapSettingsGeneration }
            ))
        }

    fun activeRequestId(): Int? = synchronized(lock) { activeRequest?.requestId }

    fun hasBackgroundWork(): Boolean = synchronized(lock) { recoveryJob?.isActive == true }

    private fun handleInit(message: Map<*, *>): List<Map<String, Any?>> {
        val version = intValue(message, KEY_PROTOCOL_VERSION)
        if (version != WATCH_PROTOCOL_VERSION) {
            eventSink(mapOf("event" to "protocolMismatch", "watchVersion" to version, "phoneVersion" to WATCH_PROTOCOL_VERSION))
            return listOf(errorMessage(ERROR_PROTOCOL_MISMATCH, CMD_INIT, "Update phone and watch together.", extra = mapOf(KEY_PROTOCOL_VERSION to WATCH_PROTOCOL_VERSION)))
        }
        WatchLocationStreamer.request(appContext)
        val currentSettings = synchronized(lock) { settings }
        val responses = mutableListOf(
            watchMessage(CMD_PHONE_READY, mapOf(KEY_PROTOCOL_VERSION to WATCH_PROTOCOL_VERSION)),
            themeMessage(currentSettings), travelModeMessage(currentSettings), unitsMessage(currentSettings),
            backlightMessage(currentSettings), mapSettingsMessage(0), mapOrientationMessage(currentSettings),
            tileAnimationMessage(currentSettings), destinationsMessage()
        )
        val providerStatus = mapTilesProvider.providerStatus()
        if (providerStatus["configured"] != true) {
            responses.add(errorMessage(ERROR_MISSING_KEY, CMD_INIT, "Missing Google API key."))
        }
        responses.add(
            WatchLocationStreamer.latestLocation(LOCATION_STALE_FOR_UI_MILLIS)?.let(WatchLocationStreamer::gpsMessageFor)
                ?: errorMessage(ERROR_LOCATION_UNAVAILABLE, CMD_GPS, "No current location fix.")
        )
        val activeMessages = activeRouteMessages()
        if (activeMessages.isNotEmpty()) {
            responses.addAll(activeMessages)
        } else {
            scheduleRouteRecovery()
        }
        eventSink(mapOf("event" to "watchReady", "protocolVersion" to WATCH_PROTOCOL_VERSION))
        return responses
    }

    private fun scheduleRouteRecovery() {
        val request = NativeActiveRoutePersistence.read(appContext) ?: return
        synchronized(lock) {
            activeRequest = request
            if (recoveryJob?.isActive == true) return
            recoveryJob = scope.launch {
                eventSink(mapOf("event" to "routeRehydrationStarted", KEY_REQUEST_ID to request.requestId))
                val result = computeRoute(request, persistOnSuccess = true)
                if (result.successful) enqueueLater(result.messages)
                eventSink(mapOf(
                    "event" to if (result.successful) "routeRehydrationSucceeded" else "routeRehydrationFailed",
                    KEY_REQUEST_ID to request.requestId,
                    "detail" to result.detail
                ))
            }
        }
    }

    private fun handleTileRequest(message: Map<*, *>): List<Map<String, Any?>> {
        val worldX = intValue(message, KEY_WORLD_X)
        val worldY = intValue(message, KEY_WORLD_Y)
        val zoom = intValue(message, KEY_TILE_ZOOM)
        val requestId = intValue(message, KEY_REQUEST_ID)
        if (worldX == null || worldY == null || zoom == null || requestId == null || requestId <= 0) {
            return listOf(errorMessage(ERROR_TILE_PROVIDER, CMD_TILE_REQUEST, "Invalid tile request.", extra = requestId?.let { mapOf(KEY_REQUEST_ID to it) }.orEmpty()))
        }
        val theme = synchronized(lock) { settings.themeMode }
        val tile = mapTilesProvider.watchTile(worldX, worldY, zoom, themeProtocolValue(intValue(message, KEY_IS_COLOR) ?: theme))
        val bytes = byteArrayValue(tile[KEY_CHUNK_DATA])
        if (tile["ok"] == true && bytes != null) {
            val width = intValue(tile, KEY_WIDTH) ?: mapTilesProvider.currentMapTileSettings().watchTileWidth
            val height = intValue(tile, KEY_HEIGHT) ?: mapTilesProvider.currentMapTileSettings().watchTileHeight
            return bytes.asList().chunked(MAX_WATCH_TILE_CHUNK_BYTES).mapIndexed { index, chunk ->
                watchMessage(CMD_TILE, mapOf(
                    KEY_WORLD_X to worldX, KEY_WORLD_Y to worldY, KEY_TILE_ZOOM to zoom,
                    KEY_WIDTH to width, KEY_HEIGHT to height, KEY_TOTAL_BYTES to bytes.size,
                    KEY_CHUNK_INDEX to index, KEY_CHUNK_OFFSET to index * MAX_WATCH_TILE_CHUNK_BYTES,
                    KEY_CHUNK_DATA to chunk.toByteArray(), KEY_REQUEST_ID to requestId
                ))
            }
        }
        return listOf(errorMessage(
            intValue(tile, KEY_ERROR_CATEGORY) ?: ERROR_TILE_PROVIDER,
            CMD_TILE_REQUEST,
            tile["detail"] as? String ?: "Watch tile provider failed.",
            worldX = worldX, worldY = worldY, zoom = zoom,
            extra = mapOf(KEY_REQUEST_ID to requestId)
        ))
    }

    private fun handleRouteRequest(message: Map<*, *>): List<Map<String, Any?>> {
        val slot = intValue(message, KEY_BUTTON_ID)
        if (slot == null || !isSavedDestinationId(slot)) return rerouteActiveRoute().messages
        val destination = synchronized(lock) { destinations.firstOrNull { it.slot == slot } }
            ?: return listOf(errorMessage(ERROR_DESTINATION_NOT_CONFIGURED, CMD_ROUTE_REQUEST, "Destination not configured.", slot))
        val request = PersistedActiveRouteRequest(
            requestId = intValue(message, KEY_REQUEST_ID)?.takeIf { it > 0 } ?: allocateRequestId(),
            originPolicy = ROUTE_ORIGIN_CURRENT_LOCATION,
            origin = null,
            destination = NativeRouteEndpoint(destination.label, destination.address, destination.latitude, destination.longitude, destination.placeId),
            travelMode = travelProtocolValue(intValue(message, KEY_IS_COLOR) ?: settings.travelMode),
            savedSlot = slot,
            updatedAtMillis = System.currentTimeMillis()
        )
        return computeRoute(request, persistOnSuccess = true).messages
    }

    private fun computeRoute(request: PersistedActiveRouteRequest, persistOnSuccess: Boolean): NativeRouteCalculation {
        val originCoordinates = if (request.originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            val origin = request.origin ?: return failure(ERROR_DESTINATION_NOT_CONFIGURED, "Route origin is missing.", request.requestId)
            origin.latitude to origin.longitude
        } else {
            val location = WatchLocationStreamer.awaitCurrentLocation(appContext, ROUTE_LOCATION_FRESH_MILLIS, LOCATION_REQUEST_TIMEOUT_MILLIS)
                ?: return failure(ERROR_LOCATION_UNAVAILABLE, "Waiting for GPS.", request.requestId)
            location.latitude to location.longitude
        }
        val generation = synchronized(lock) { ++routeGeneration }
        val route = mapTilesProvider.computeRoute(
            originLatitude = originCoordinates.first,
            originLongitude = originCoordinates.second,
            destinationAddress = request.destination.address,
            destinationLatitude = request.destination.latitude,
            destinationLongitude = request.destination.longitude,
            travelMode = providerTravelMode(request.travelMode),
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (route["ok"] != true) {
            val category = intValue(route, KEY_ERROR_CATEGORY) ?: ERROR_ROUTE_PROVIDER
            val detail = route["detail"] as? String ?: if (category == ERROR_NO_ROUTE) "No route found." else "Route provider failed."
            if (category == ERROR_NO_ROUTE) clearActiveRoute(request.requestId)
            return NativeRouteCalculation(
                request.requestId,
                if (category == ERROR_NO_ROUTE) listOf(
                    routePointsMessage(emptyList(), generation, request, false),
                    errorMessage(category, CMD_ROUTE_REQUEST, detail, request.savedSlot ?: 0, extra = mapOf(KEY_REQUEST_ID to request.requestId))
                ) else listOf(errorMessage(category, CMD_ROUTE_REQUEST, detail, request.savedSlot ?: 0, extra = mapOf(KEY_REQUEST_ID to request.requestId))),
                false, category, detail
            )
        }
        val points = listOfMaps(route["routePoints"])
        if (points.size < 2) return failure(ERROR_ROUTE_PROVIDER, "Route geometry is invalid.", request.requestId)
        val fullPoints = listOfMaps(route["fullRoutePoints"]).ifEmpty { points }
        val steps = listOfMaps(route["steps"])
        synchronized(lock) {
            if (generation != routeGeneration) return NativeRouteCalculation(request.requestId, emptyList(), false, detail = "Route superseded.")
            routePoints = points
            fullRoutePoints = fullPoints
            routeSteps = steps
            activeRequest = request.copy(updatedAtMillis = System.currentTimeMillis())
            settings = settings.copy(travelMode = request.travelMode)
            saveNativeDisplaySettings(appContext, settings)
            if (persistOnSuccess) NativeActiveRoutePersistence.write(appContext, activeRequest!!)
        }
        val messages = mutableListOf(routePointsMessage(points, generation, request, steps.isNotEmpty()))
        navStepsMessage(0, generation, request.requestId)?.let(messages::add)
        return NativeRouteCalculation(request.requestId, messages, true)
    }

    private fun activeRouteMessages(): List<Map<String, Any?>> {
        val snapshot = synchronized(lock) {
            val request = activeRequest ?: return emptyList()
            if (routePoints.size < 2) return emptyList()
            Triple(request, routeGeneration, routePoints to routeSteps)
        }
        val messages = mutableListOf(routePointsMessage(snapshot.third.first, snapshot.second, snapshot.first, snapshot.third.second.isNotEmpty()))
        navStepsMessage(0, snapshot.second, snapshot.first.requestId)?.let(messages::add)
        return messages
    }

    private fun handleNavSteps(message: Map<*, *>): List<Map<String, Any?>> {
        val request = synchronized(lock) { activeRequest } ?: return emptyList()
        val requestedId = intValue(message, KEY_REQUEST_ID)
        if (requestedId != null && requestedId != request.requestId) return emptyList()
        return listOfNotNull(navStepsMessage(intValue(message, KEY_BUTTON_ID) ?: 0, routeGeneration, request.requestId))
    }

    private fun handleRouteWindowRequest(message: Map<*, *>): List<Map<String, Any?>> {
        val request = synchronized(lock) { activeRequest } ?: return emptyList()
        val requestedId = intValue(message, KEY_REQUEST_ID)
        if (requestedId != null && requestedId != request.requestId) return emptyList()
        val generation = intValue(message, KEY_TOTAL_BYTES) ?: routeGeneration
        val points = synchronized(lock) { fullRoutePoints }
        if (generation != routeGeneration || points.size < 2) return emptyList()
        return listOf(watchMessage(CMD_ROUTE_WINDOW_POINTS, mapOf(
            KEY_WORLD_X to (intValue(message, KEY_WORLD_X) ?: 0),
            KEY_WORLD_Y to (intValue(message, KEY_WORLD_Y) ?: 0),
            KEY_TILE_ZOOM to (intValue(message, KEY_TILE_ZOOM) ?: ROUTE_WORLD_ZOOM),
            KEY_WIDTH to (intValue(message, KEY_WIDTH) ?: 1).coerceAtLeast(1),
            KEY_HEIGHT to (intValue(message, KEY_HEIGHT) ?: 1).coerceAtLeast(1),
            KEY_TOTAL_BYTES to generation,
            KEY_REQUEST_ID to request.requestId,
            KEY_CHUNK_DATA to encodeRoutePoints(points.take(MAX_ROUTE_POINTS))
        )))
    }

    private fun routePointsMessage(points: List<Map<*, *>>, generation: Int, request: PersistedActiveRouteRequest, expectsSteps: Boolean): Map<String, Any?> =
        watchMessage(CMD_ROUTE_POINTS, mapOf(
            KEY_BUTTON_ID to 1,
            KEY_IS_COLOR to request.travelMode,
            KEY_TOTAL_BYTES to generation,
            KEY_CHUNK_INDEX to if (expectsSteps) 1 else 0,
            KEY_REQUEST_ID to request.requestId,
            KEY_CHUNK_DATA to encodeRoutePoints(points)
        ))

    private fun navStepsMessage(firstIndex: Int, generation: Int, requestId: Int): Map<String, Any?>? {
        val steps = synchronized(lock) { routeSteps }
        val payload = encodeNavSteps(steps, firstIndex) ?: return null
        return watchMessage(CMD_NAV_STEPS, mapOf(
            KEY_CHUNK_DATA to payload,
            KEY_TOTAL_BYTES to generation,
            KEY_REQUEST_ID to requestId
        ))
    }

    private fun destinationsMessage(): Map<String, Any?> =
        watchMessage(CMD_DESTINATIONS, encodeDestinations(synchronized(lock) { destinations.toList() }).let {
            mapOf(KEY_TOTAL_BYTES to it.size, KEY_CHUNK_DATA to it)
        })

    private fun updateScalarSetting(command: Int, value: Int?): List<Map<String, Any?>> {
        synchronized(lock) {
            settings = when (command) {
                CMD_THEME -> settings.copy(themeMode = themeProtocolValue(value))
                CMD_TRAVEL_MODE -> settings.copy(travelMode = travelProtocolValue(value))
                CMD_UNITS -> settings.copy(unitsMode = unitsProtocolValue(value))
                CMD_BACKLIGHT -> settings.copy(backlightMode = backlightProtocolValue(value))
                CMD_MAP_ORIENTATION -> settings.copy(mapOrientation = mapOrientationProtocolValue(value))
                CMD_TILE_ANIMATION -> settings.copy(tileAnimationMode = tileAnimationProtocolValue(value))
                else -> settings
            }
            saveNativeDisplaySettings(appContext, settings)
            return when (command) {
                CMD_THEME -> listOf(themeMessage(settings), mapSettingsMessage(4))
                CMD_TRAVEL_MODE -> listOf(travelModeMessage(settings))
                CMD_UNITS -> listOf(unitsMessage(settings))
                CMD_BACKLIGHT -> listOf(backlightMessage(settings))
                CMD_MAP_ORIENTATION -> listOf(mapOrientationMessage(settings))
                CMD_TILE_ANIMATION -> listOf(tileAnimationMessage(settings))
                else -> emptyList()
            }
        }
    }

    private fun themeMessage(value: NativeDisplaySettings) = watchMessage(CMD_THEME, mapOf(KEY_BUTTON_ID to value.themeMode))
    private fun travelModeMessage(value: NativeDisplaySettings) = watchMessage(CMD_TRAVEL_MODE, mapOf(KEY_BUTTON_ID to value.travelMode))
    private fun unitsMessage(value: NativeDisplaySettings) = watchMessage(CMD_UNITS, mapOf(KEY_BUTTON_ID to value.unitsMode))
    private fun backlightMessage(value: NativeDisplaySettings) = watchMessage(CMD_BACKLIGHT, mapOf(KEY_BUTTON_ID to value.backlightMode))
    private fun tileAnimationMessage(value: NativeDisplaySettings) = watchMessage(CMD_TILE_ANIMATION, mapOf(KEY_BUTTON_ID to value.tileAnimationMode))
    private fun mapOrientationMessage(value: NativeDisplaySettings) = watchMessage(CMD_MAP_ORIENTATION, mapOf(
        KEY_BUTTON_ID to value.mapOrientation,
        KEY_TOTAL_BYTES to synchronized(lock) { ++displaySettingsGeneration }
    ))

    private fun failure(category: Int, detail: String, requestId: Int = allocateRequestId()) =
        NativeRouteCalculation(requestId, listOf(errorMessage(category, CMD_ROUTE_REQUEST, detail, extra = mapOf(KEY_REQUEST_ID to requestId))), false, category, detail)

    private fun errorMessage(
        category: Int,
        failedCommand: Int,
        text: String,
        offset: Int = 0,
        worldX: Int? = null,
        worldY: Int? = null,
        zoom: Int? = null,
        extra: Map<String, Any?> = emptyMap()
    ): Map<String, Any?> {
        val fields = linkedMapOf<String, Any?>(
            KEY_BUTTON_ID to category,
            KEY_CHUNK_INDEX to failedCommand,
            KEY_CHUNK_OFFSET to offset,
            KEY_INSTRUCTION to truncatedUtf8Text(redactDiagnosticCredentials(text), MAX_WATCH_TEXT_BYTES)
        )
        worldX?.let { fields[KEY_WORLD_X] = it }
        worldY?.let { fields[KEY_WORLD_Y] = it }
        zoom?.let { fields[KEY_TILE_ZOOM] = it }
        fields.putAll(extra)
        return watchMessage(CMD_ERROR_STATE, fields)
    }

    private fun allocateRequestId(): Int {
        while (true) {
            val current = nextRequestId.getAndUpdate { if (it >= Int.MAX_VALUE - 1) 1 else it + 1 }
            if (current > 0) return current
        }
    }
}
