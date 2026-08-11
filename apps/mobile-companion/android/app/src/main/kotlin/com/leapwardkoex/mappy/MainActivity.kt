package com.leapwardkoex.mappy

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingNotificationPermissionResult: MethodChannel.Result? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var apiKeyStore: ApiKeyStore
    private lateinit var mapTilesProvider: GoogleMapTilesProvider
    private lateinit var watchRuntime: MappyWatchRuntime
    private val nativeDestinations = mutableListOf<NativeDestination>()
    private var nativeRoutePoints: List<Map<*, *>> = emptyList()
    private var nativeFullRoutePoints: List<Map<*, *>> = emptyList()
    private var nativeRouteSteps: List<Map<*, *>> = emptyList()
    private var nativeActiveRouteOriginPolicy = ROUTE_ORIGIN_CURRENT_LOCATION
    private var nativeActiveRouteOrigin: NativeRouteEndpoint? = null
    private var nativeActiveRouteTarget: NativeRouteEndpoint? = null
    private var nativeActiveRouteSlot: Int? = null
    private var nativeActiveRouteSummary: Map<String, Any?>? = null
    private var nativeActiveRouteMode: Int? = null
    private var nativeLastRouteRequestedAtMillis = 0L
    private var nativeLastRouteError: Map<String, Any?>? = null
    private val nativeDiagnosticEvents = ArrayDeque<Map<String, Any?>>()
    private var nextDiagnosticEventId = 1
    private var nativeThemeMode = DEFAULT_THEME_MODE
    private var nativeTravelMode = DEFAULT_TRAVEL_PROTOCOL_MODE
    private var nativeUnitsMode = DEFAULT_UNITS_MODE
    private var nativeBacklightMode = 0
    private var nativeMapOrientation = DEFAULT_MAP_ORIENTATION
    private var nativeTileAnimationMode = DEFAULT_TILE_ANIMATION_MODE
    private var nativeRouteGeneration = 0
    private var nativeMapSettingsGeneration = 0
    private var nativeDisplaySettingsGeneration = 0
    private val nativePendingPhoneMessages = mutableListOf<Map<String, Any?>>()
    private val runtimeEventSink: (Map<String, Any?>) -> Unit = { event -> handleWatchBridgeEvent(event) }
    private var bridgeEventSink: EventChannel.EventSink? = null
    private var lastEmittedSetupState: String? = null
    private var lastEmittedPermissionState: String? = null
    private var lastEmittedNotificationPermissionState: String? = null
    private var lastSafeErrorCategory: Int? = null
    private var lastSafeErrorText: String? = null
    private var lastTileFailureDiagnosticAtMillis = 0L
    private var nativeLastShareStatus: Map<String, Any?>? = null
    private var lastHandledShareFingerprint: String? = null
    private var lastHandledShareAtMillis = 0L

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        Log.i(LOG_TAG, "Configuring Mappy native bridge.")
        watchRuntime = MappyWatchRuntime.get(applicationContext)
        apiKeyStore = watchRuntime.apiKeyStore
        mapTilesProvider = watchRuntime.mapTilesProvider
        loadDisplaySettings()
        loadNativeDestinations()
        loadDiagnosticEvents()
        recordDiagnosticEntry(
            source = "android_bridge",
            level = "info",
            eventName = "app_started",
            message = "App bridge started."
        )
        super.configureFlutterEngine(flutterEngine)
        watchRuntime.attachUi(runtimeEventSink)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BRIDGE_METHOD_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getBridgeStatus" -> result.success(bridgeStatusPayload())
                "startWatchApp" -> {
                    watchRuntime.startWatchApp()
                    emitBridgeStatus()
                    result.success(bridgeStatusPayload())
                }
                "requestNotificationPermission" -> requestNotificationPermission(result)
                "exportDiagnostics" -> {
                    emitDiagnosticEvent(
                        source = "flutter",
                        category = 0,
                        failedCommand = 0,
                        detail = "Diagnostics exported.",
                        eventName = "diagnostics_exported"
                    )
                    val payload = exportDiagnosticsPayload()
                    result.success(payload + writeDiagnosticsExportFile(payload))
                }
                "clearDiagnostics" -> {
                    clearDiagnosticEvents()
                    result.success(exportDiagnosticsPayload())
                }
                "clearRouteCache" -> {
                    watchRuntime.clearActiveRoute()
                    result.success(exportDiagnosticsPayload())
                }
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BRIDGE_EVENT_CHANNEL
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    bridgeEventSink = events
                    emitBridgeStatus()
                    emitProviderStatusEvent()
                    emitLocationStatusEvent()
                    synchronized(this@MainActivity) { nativeLastShareStatus }?.let { status ->
                        emitBridgeEvent(status)
                    }
                }

                override fun onCancel(arguments: Any?) {
                    bridgeEventSink = null
                }
            }
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCATION_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPermissionState" -> result.success(permissionState())
                "requestLocationPermission" -> requestLocationPermission(result)
                "getCurrentLocation" -> currentLocation(
                    result,
                    call.argument<Int>("timeoutMillis")?.toLong()
                )
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROVIDER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "storeApiKey" -> {
                    val apiKey = call.argument<String>("apiKey")
                    if (apiKey == null) {
                        result.error("missing_api_key", "API key argument is required.", null)
                    } else {
                        mapTilesProvider.clearProviderSessions()
                        val status = apiKeyStore.storeApiKey(apiKey)
                        recordDiagnosticEntry(
                            source = "android_bridge",
                            level = "info",
                            eventName = "api_key_stored",
                            message = "API key stored.",
                            provider = "google_map_tiles"
                        )
                        result.success(status)
                        emitProviderStatusEvent(status)
                        emitBridgeStatus()
                    }
                }
                "clearApiKey" -> {
                    mapTilesProvider.clearProviderSessions()
                    val status = apiKeyStore.clearApiKey()
                    recordDiagnosticEntry(
                        source = "android_bridge",
                        level = "info",
                        eventName = "api_key_cleared",
                        message = "API key cleared.",
                        provider = "google_map_tiles"
                    )
                    result.success(status)
                    emitProviderStatusEvent(status)
                    emitBridgeStatus()
                }
                "getProviderStatus" -> {
                    val status = mapTilesProvider.providerStatus()
                    result.success(status)
                    emitProviderStatusEvent(status)
                }
                "getMapTileSettings" -> result.success(mapTilesProvider.mapTileSettingsStatus())
                "setMapTileSettings" -> {
                    val settingsArguments = call.arguments as? Map<*, *>
                    if (settingsArguments == null) {
                        result.error("missing_map_tile_settings", "Map tile settings dictionary is required.", null)
                    } else {
                        val previousSettings = mapTilesProvider.currentMapTileSettings()
                        val settings = GoogleMapTilesProvider.MapTileSettings.fromMap(settingsArguments)
                        saveMapTileSettings(this, settings)
                        val response = mapTilesProvider.updateMapTileSettings(settings)
                        val changed = response["changed"] == true
                        val channelResponse = response + mapOf(
                            "watchMessage" to if (changed) {
                                watchRuntime.dispatcher.mapSettingsMessage(
                                    reason = mapSettingsReason(previousSettings, settings)
                                )
                            } else {
                                null
                            }
                        )
                        result.success(channelResponse)
                        (response["providerStatus"] as? Map<*, *>)?.let { providerStatus ->
                            emitProviderStatusEvent(stringKeyMap(providerStatus))
                        }
                    }
                }
                "clearMapTileCache" -> {
                    mapTilesProvider.clearProviderSessions()
                    val response = mapTilesProvider.mapTileSettingsStatus() + mapOf(
                        "changed" to true,
                        "detail" to "Map tile caches were cleared.",
                        "watchMessage" to watchRuntime.dispatcher.mapSettingsMessage(reason = 0)
                    )
                    recordDiagnosticEntry(
                        source = "flutter",
                        level = "info",
                        eventName = "cache_cleared",
                        message = "Tile cache cleared.",
                        provider = "google_map_tiles"
                    )
                    result.success(response)
                    (response["providerStatus"] as? Map<*, *>)?.let { providerStatus ->
                        emitProviderStatusEvent(stringKeyMap(providerStatus))
                    }
                }
                "clearProviderValidationCache" -> {
                    val status = mapTilesProvider.clearProviderValidationCache()
                    recordDiagnosticEntry(
                        source = "flutter",
                        level = "info",
                        eventName = "cache_cleared",
                        message = "Provider validation cache cleared.",
                        provider = "google_map_tiles"
                    )
                    result.success(status)
                    emitProviderStatusEvent(status)
                    emitBridgeStatus()
                }
                "validateProviderSetup" -> validateProviderSetup(result)
                "geocodeDestination" -> {
                    val addressText = call.argument<String>("addressText")
                    if (addressText == null) {
                        result.error("missing_address", "Destination address is required.", null)
                    } else {
                        runProviderTask(result) {
                            mapTilesProvider.geocodeDestination(
                                addressText = addressText,
                                language = call.argument<String>("language") ?: DEFAULT_LANGUAGE,
                                region = call.argument<String>("region") ?: DEFAULT_REGION
                            )
                        }
                    }
                }
                "searchPlaces", "autocompleteDestination" -> {
                    val input = call.argument<String>("input")
                    if (input == null) {
                        result.error("missing_input", "Place search input is required.", null)
                    } else {
                        runProviderTask(result) {
                            mapTilesProvider.autocompleteDestination(
                                input = input,
                                originLatitude = call.argument<Double>("originLatitude"),
                                originLongitude = call.argument<Double>("originLongitude"),
                                sessionToken = call.argument<String>("sessionToken"),
                                language = call.argument<String>("language") ?: DEFAULT_LANGUAGE,
                                region = call.argument<String>("region") ?: DEFAULT_REGION
                            )
                        }
                    }
                }
                "resolvePlace" -> {
                    val placeId = call.argument<String>("placeId")
                    if (placeId == null) {
                        result.error("missing_place_id", "Place ID is required.", null)
                    } else {
                        runProviderTask(result) {
                            mapTilesProvider.resolvePlace(
                                placeId = placeId,
                                sessionToken = call.argument<String>("sessionToken"),
                                language = call.argument<String>("language") ?: DEFAULT_LANGUAGE,
                                region = call.argument<String>("region") ?: DEFAULT_REGION
                            )
                        }
                    }
                }
                "computeRoute" -> {
                    val originLatitude = call.argument<Double>("originLatitude")
                    val originLongitude = call.argument<Double>("originLongitude")
                    if (originLatitude == null || originLongitude == null) {
                        result.error("missing_origin", "Route origin latitude and longitude are required.", null)
                    } else {
                        runProviderTask(result) {
                            mapTilesProvider.computeRoute(
                                originLatitude = originLatitude,
                                originLongitude = originLongitude,
                                destinationAddress = call.argument<String>("destinationAddress"),
                                destinationLatitude = call.argument<Double>("destinationLatitude"),
                                destinationLongitude = call.argument<Double>("destinationLongitude"),
                                travelMode = call.argument<String>("travelMode") ?: DEFAULT_TRAVEL_MODE,
                                language = call.argument<String>("language") ?: DEFAULT_LANGUAGE,
                                region = call.argument<String>("region") ?: DEFAULT_REGION
                            )
                        }
                    }
                }
                "getPreviewTile" -> {
                    val latitude = call.argument<Double>("latitude")
                    val longitude = call.argument<Double>("longitude")
                    val zoom = call.argument<Int>("zoom") ?: DEFAULT_PREVIEW_ZOOM
                    if (latitude == null || longitude == null) {
                        result.error("missing_location", "Latitude and longitude are required.", null)
                    } else {
                        runProviderTask(result) {
                            mapTilesProvider.previewTile(latitude, longitude, zoom)
                        }
                    }
                }
                "getWatchTile" -> {
                    val worldX = call.argument<Int>("worldX")
                    val worldY = call.argument<Int>("worldY")
                    val zoom = call.argument<Int>("zoom") ?: DEFAULT_PREVIEW_ZOOM
                    val themeMode = call.argument<Int>("themeMode") ?: DEFAULT_THEME_MODE
                    if (worldX == null || worldY == null) {
                        result.error("missing_tile_origin", "Watch tile world x and y are required.", null)
                    } else {
                        runProviderTask(result) {
                            mapTilesProvider.watchTile(worldX, worldY, zoom, themeMode)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            WATCH_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "handleWatchMessage" -> {
                    val message = call.arguments as? Map<*, *>
                    if (message == null) {
                        result.error("missing_message", "Watch message dictionary is required.", null)
                    } else {
                        runWatchTask(result) { watchRuntime.dispatcher.dispatch(message) }
                    }
                }
                "setDestination" -> {
                    val destination = call.arguments as? Map<*, *>
                    if (destination == null) {
                        result.error("missing_destination", "Destination dictionary is required.", null)
                    } else {
                        runWatchTask(result) {
                            watchRuntime.dispatcher.setDestination(destination).also(watchRuntime::enqueueAll)
                        }
                    }
                }
                "setDestinations" -> {
                    val destinations = call.arguments as? List<*>
                    if (destinations == null) {
                        result.error("missing_destinations", "Destination list is required.", null)
                    } else {
                        runWatchTask(result) {
                            watchRuntime.dispatcher.setDestinations(destinations).also(watchRuntime::enqueueAll)
                        }
                    }
                }
                "getDestinations" -> result.success(watchRuntime.dispatcher.exportDestinations())
                "startNavigation" -> {
                    val request = call.arguments as? Map<*, *>
                    if (request == null) {
                        result.error("missing_navigation", "Navigation request dictionary is required.", null)
                    } else {
                        watchRuntime.startNavigation(request) { response ->
                            mainHandler.post { result.success(response) }
                        }
                    }
                }
                "rerouteActiveRoute" -> watchRuntime.rerouteActiveRoute { response ->
                    mainHandler.post { result.success(response) }
                }
                "clearActiveRoute" -> {
                    val response = watchRuntime.clearActiveRoute()
                    result.success(response)
                }
                "getSettings" -> result.success(watchRuntime.dispatcher.displaySettings())
                "getTransportStatus" -> result.success(watchRuntime.status())
                "startWatchApp" -> {
                    watchRuntime.startWatchApp()
                    emitBridgeStatus()
                    result.success(watchStatusPayload())
                }
                "setSettings" -> {
                    val settings = call.arguments as? Map<*, *>
                    if (settings == null) {
                        result.error("missing_settings", "Settings dictionary is required.", null)
                    } else {
                        runWatchTask(result) {
                            watchRuntime.dispatcher.setSettings(settings).also(watchRuntime::enqueueAll)
                        }
                    }
                }
                "sendPhoneMessage" -> {
                    val message = call.arguments as? Map<*, *>
                    if (message == null) {
                        result.error("missing_message", "Phone message dictionary is required.", null)
                    } else {
                        watchRuntime.enqueue(message)
                        result.success(true)
                    }
                }
                else -> result.notImplemented()
            }
        }
        handleIncomingShareIntent(intent)
        Log.i(LOG_TAG, "Mappy native bridge configured.")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingShareIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridgeEventSink = null
        watchRuntime.detachUi(runtimeEventSink)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onResume() {
        super.onResume()
        emitLocationStatusEvent()
        emitBridgeStatus()
        if (isGpsStreamingRequested()) {
            startGpsStreamingIfPossible()
        }
    }

    override fun onPause() {
        if (isGpsStreamingRequested() && !hasActiveWatchSession()) {
            stopGpsStreaming(
                sendError = true,
                text = "Location updates paused while the phone app is backgrounded."
            )
        }
        super.onPause()
    }

    private fun hasActiveWatchSession(): Boolean =
        (::watchRuntime.isInitialized && watchRuntime.status()["watchAppActive"] == true) ||
            WatchSessionForegroundService.isActive

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == LOCATION_PERMISSION_REQUEST_CODE) {
            val result = pendingPermissionResult
            pendingPermissionResult = null
            val state = permissionState()
            result?.success(state)
            recordLocationPermissionChanged(state)
            if (state == "grantedPrecise" || state == "grantedApproximate") {
                if (isGpsStreamingRequested()) {
                    startGpsStreamingIfPossible()
                }
            } else if (isGpsStreamingRequested()) {
                stopGpsStreaming(
                    sendError = true,
                    text = "Location permission is required for live watch GPS."
                )
            }
            emitBridgeStatus()
            return
        }

        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            val result = pendingNotificationPermissionResult
            pendingNotificationPermissionResult = null
            recordNotificationPermissionChanged(notificationPermissionState())
            emitBridgeStatus()
            result?.success(bridgeStatusPayload())
            return
        }

        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    private fun requestLocationPermission(result: MethodChannel.Result) {
        if (hasFineLocation() || hasCoarseLocation()) {
            if (!WatchLocationStreamer.hasBackgroundLocation(this)) {
                WatchLocationStreamer.openAppLocationSettings(this)
            }
            result.success(permissionState())
            return
        }

        if (pendingPermissionResult != null) {
            result.error("permission_request_in_flight", "Location permission request is already in progress.", null)
            return
        }

        getPreferences(Context.MODE_PRIVATE)
            .edit()
            .putBoolean(LOCATION_PERMISSION_REQUESTED_KEY, true)
            .apply()

        pendingPermissionResult = result
        requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION
            ),
            LOCATION_PERMISSION_REQUEST_CODE
        )
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || hasNotificationPermission()) {
            result.success(bridgeStatusPayload())
            return
        }

        if (pendingNotificationPermissionResult != null) {
            result.error(
                "notification_permission_request_in_flight",
                "Notification permission request is already in progress.",
                null
            )
            return
        }

        getPreferences(Context.MODE_PRIVATE)
            .edit()
            .putBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, true)
            .apply()

        pendingNotificationPermissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE
        )
    }

    private fun currentLocation(result: MethodChannel.Result, timeoutMillis: Long? = null) {
        WatchLocationStreamer.currentLocation(
            applicationContext,
            timeoutMillis ?: LOCATION_REQUEST_TIMEOUT_MILLIS
        ) { location ->
            location?.let { recordLocationFixUpdated(it) }
            result.success(location?.let { WatchLocationStreamer.locationPayloadFor(it) })
        }
    }

    private fun permissionState(): String {
        val wasRequested = getPreferences(Context.MODE_PRIVATE)
            .getBoolean(LOCATION_PERMISSION_REQUESTED_KEY, false)
        return WatchLocationStreamer.permissionState(this, wasRequested)
    }

    private fun notificationPermissionState(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return "notRequired"
        }
        if (hasNotificationPermission()) {
            return "granted"
        }

        val wasRequested = getPreferences(Context.MODE_PRIVATE)
            .getBoolean(NOTIFICATION_PERMISSION_REQUESTED_KEY, false)
        if (!wasRequested) {
            return "requestAvailable"
        }

        return if (!shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS)) {
            "permanentlyDenied"
        } else {
            "denied"
        }
    }

    private fun hasFineLocation(): Boolean =
        WatchLocationStreamer.hasFineLocation(this)

    private fun hasCoarseLocation(): Boolean =
        WatchLocationStreamer.hasCoarseLocation(this)

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun hasEnabledLocationProvider(): Boolean {
        return WatchLocationStreamer.hasEnabledLocationProvider(this)
    }

    private fun requestGpsStreaming() {
        WatchLocationStreamer.request(applicationContext)
    }

    private fun isGpsStreamingRequested(): Boolean =
        WatchLocationStreamer.isRequested()

    private fun startGpsStreamingIfPossible() {
        if (isGpsStreamingRequested()) WatchLocationStreamer.request(applicationContext)
    }

    private fun restartGpsStreaming() {
        mainHandler.post {
            val shouldRestart = isGpsStreamingRequested()
            stopGpsStreaming(sendError = false)
            if (shouldRestart) {
                startGpsStreamingIfPossible()
            }
        }
    }

    private fun stopGpsStreaming(
        sendError: Boolean,
        text: String = "Live watch GPS stopped."
    ) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { stopGpsStreaming(sendError, text) }
            return
        }
        WatchLocationStreamer.stop(applicationContext, sendError, text)
    }

    private fun clearGpsStreamingState() {
        WatchLocationStreamer.stop(applicationContext, sendError = false)
    }

    private fun runProviderTask(result: MethodChannel.Result, block: () -> Map<String, Any?>) {
        Thread {
            val response = try {
                block()
            } catch (_: Exception) {
                mapOf(
                    "ok" to false,
                    "providerStatus" to apiKeyStore.getStatus(),
                    "detail" to "Provider task failed."
                )
            }
            mainHandler.post {
                result.success(response)
                (response["providerStatus"] as? Map<*, *>)?.let { providerStatus ->
                    emitProviderStatusEvent(stringKeyMap(providerStatus))
                    emitBridgeStatus()
                }
            }
        }.start()
    }

    private fun validateProviderSetup(result: MethodChannel.Result) {
        recordDiagnosticEntry(
            source = "provider",
            level = "info",
            eventName = "provider_validation_started",
            message = "Provider validation started.",
            provider = "google_map_tiles"
        )
        Thread {
            val response = try {
                mapTilesProvider.validateProviderSetup()
            } catch (_: Exception) {
                mapOf(
                    "configured" to false,
                    "validationState" to "networkUnavailable",
                    "validationDetail" to "Provider validation failed."
                )
            }
            mainHandler.post {
                val validationState = response["validationState"] as? String
                val httpStatus = intValue(response, "validationHttpStatus")
                recordDiagnosticEntry(
                    source = "provider",
                    level = if (validationState == "valid") "info" else "warn",
                    eventName = "provider_validation_finished",
                    message = response["validationDetail"] as? String
                        ?: "Provider validation finished.",
                    provider = "google_map_tiles",
                    providerErrorClass = validationState,
                    httpStatus = httpStatus
                )
                result.success(response)
                emitProviderStatusEvent(response)
                emitBridgeStatus()
            }
        }.start()
    }

    private fun runWatchTask(result: MethodChannel.Result, block: () -> List<Map<String, Any?>>) {
        watchRuntime.submit(block) { outcome ->
            val response = outcome.getOrElse {
                listOf(
                    errorMessage(
                        category = ERROR_ROUTE_PROVIDER,
                        failedCommand = 0,
                        text = "Watch dispatcher task failed."
                    )
                )
            }
            mainHandler.post { result.success(response) }
        }
    }

    private fun handleIncomingShareIntent(intent: Intent?) {
        val text = shareTextFromIntent(intent) ?: return
        val now = SystemClock.elapsedRealtime()
        val fingerprint = "${intent?.action}:${intent?.type}:${text.hashCode()}"
        val shouldHandle = synchronized(this) {
            val duplicate = lastHandledShareFingerprint == fingerprint &&
                now - lastHandledShareAtMillis < SHARE_INTENT_DUPLICATE_WINDOW_MILLIS
            if (!duplicate) {
                lastHandledShareFingerprint = fingerprint
                lastHandledShareAtMillis = now
            }
            !duplicate
        }
        if (!shouldHandle) {
            return
        }

        val sourcePackage = sourcePackageFromIntent(intent)
        watchRuntime.submit({ processIncomingGoogleMapsShare(text, sourcePackage) }) { outcome ->
            if (outcome.isFailure) {
                emitShareStatus(
                    state = "error",
                    detail = "Shared route processing failed.",
                    errorCategory = ERROR_ROUTE_PROVIDER
                )
            }
        }
    }

    private fun shareTextFromIntent(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_SEND) {
            return null
        }
        val mimeType = intent.type?.lowercase(Locale.US) ?: return null
        if (mimeType != "text/plain") {
            return null
        }
        return intent.getStringExtra(Intent.EXTRA_TEXT)
            ?.trim()
            ?.takeIf { it.isNotBlank() }
    }

    private fun sourcePackageFromIntent(intent: Intent?): String? {
        val referrer = intent?.getStringExtra(Intent.EXTRA_REFERRER_NAME)
            ?.removePrefix("android-app://")
            ?.takeIf { it.isNotBlank() }
        return referrer ?: intent?.getPackage()
    }

    private fun processIncomingGoogleMapsShare(rawText: String, sourcePackage: String?) {
        emitShareStatus(
            state = "parsing",
            detail = "Parsing Google Maps share."
        )

        val parsed = when (val initial = GoogleMapsShareParser.parse(rawText, sourcePackage)) {
            is GoogleMapsShareParser.Result.RedirectRequired -> {
                emitShareStatus(
                    state = "resolvingShortLink",
                    detail = "Resolving Google Maps short link.",
                    safeHost = initial.safeHost
                )
                val redirect = resolveGoogleMapsShareRedirect(initial.url)
                if (redirect == null) {
                    recordDiagnosticEntry(
                        source = "google_maps_share",
                        level = "error",
                        eventName = "share_redirect_failed",
                        message = "Google Maps short link could not be resolved.",
                        errorCategory = ERROR_NETWORK_UNAVAILABLE,
                        safeUrlHost = initial.safeHost
                    )
                    emitShareStatus(
                        state = "error",
                        detail = "Google Maps short link could not be resolved.",
                        safeHost = initial.safeHost,
                        errorCategory = ERROR_NETWORK_UNAVAILABLE
                    )
                    return
                }
                GoogleMapsShareParser.parse(
                    rawText,
                    sourcePackage,
                    resolvedUrl = redirect.url,
                    redirectHopCount = redirect.hopCount
                )
            }
            else -> initial
        }

        when (parsed) {
            is GoogleMapsShareParser.Result.Parsed -> startSharedGoogleMapsRoute(parsed.share)
            is GoogleMapsShareParser.Result.RedirectRequired -> {
                recordDiagnosticEntry(
                    source = "google_maps_share",
                    level = "error",
                    eventName = "share_redirect_failed",
                    message = "Google Maps short link redirect did not reach a Maps URL.",
                    errorCategory = ERROR_NETWORK_UNAVAILABLE,
                    safeUrlHost = parsed.safeHost
                )
                emitShareStatus(
                    state = "error",
                    detail = "Google Maps short link did not resolve to a supported Maps URL.",
                    safeHost = parsed.safeHost,
                    errorCategory = ERROR_NETWORK_UNAVAILABLE
                )
            }
            is GoogleMapsShareParser.Result.Rejected -> {
                recordDiagnosticEntry(
                    source = "google_maps_share",
                    level = "warn",
                    eventName = "share_rejected",
                    message = parsed.reason,
                    errorCategory = ERROR_ROUTE_PROVIDER,
                    safeUrlHost = parsed.safeHost
                )
                emitShareStatus(
                    state = "unsupported",
                    detail = parsed.reason,
                    safeHost = parsed.safeHost,
                    errorCategory = ERROR_ROUTE_PROVIDER
                )
            }
        }
    }

    private fun resolveGoogleMapsShareRedirect(url: String): ShareRedirectResolution? {
        var currentUrl = url
        var hopCount = 0
        while (hopCount < MAX_SHARE_REDIRECT_HOPS) {
            val currentHost = GoogleMapsShareParser.safeHost(currentUrl) ?: return null
            if (!isAllowedShareRedirectHost(currentHost)) {
                return null
            }
            if (currentHost in SHARE_FINAL_GOOGLE_MAPS_HOSTS) {
                return ShareRedirectResolution(currentUrl, hopCount)
            }

            val connection = try {
                (URL(currentUrl).openConnection() as HttpURLConnection).apply {
                    instanceFollowRedirects = false
                    requestMethod = "GET"
                    connectTimeout = SHARE_REDIRECT_TIMEOUT_MILLIS
                    readTimeout = SHARE_REDIRECT_TIMEOUT_MILLIS
                    useCaches = false
                }
            } catch (_: Exception) {
                return null
            }

            try {
                val status = connection.responseCode
                if (status !in 300..399) {
                    return null
                }
                val location = connection.getHeaderField("Location") ?: return null
                val nextUrl = URL(URL(currentUrl), location).toString()
                if (!nextUrl.startsWith("https://", ignoreCase = true)) {
                    return null
                }
                currentUrl = nextUrl
                hopCount += 1
            } catch (_: Exception) {
                return null
            } finally {
                connection.disconnect()
            }
        }
        return null
    }

    private fun isAllowedShareRedirectHost(host: String): Boolean =
        host in SHARE_FINAL_GOOGLE_MAPS_HOSTS || host in SHARE_SHORT_LINK_HOSTS

    private fun startSharedGoogleMapsRoute(share: GoogleMapsShareParser.Share) {
        recordDiagnosticEntry(
            source = "google_maps_share",
            level = "info",
            eventName = "share_received",
            message = "Google Maps share received.",
            shareType = share.type.channelName,
            safeUrlHost = share.safeHost,
            redirectHopCount = share.redirectHopCount,
            explicitOrigin = share.explicitOrigin,
            destinationHasCoordinates = share.destination.hasCoordinates,
            travelMode = shareTravelModeName(share)
        )

        clearNativeRouteCache(recordDiagnostic = true, source = "google_maps_share")
        watchRuntime.clearActiveRoute()

        emitShareStatus(
            state = "resolvingEndpoint",
            share = share,
            detail = "Resolving shared origin and destination."
        )

        val requestedMode = share.travelMode?.protocolValue
            ?: synchronized(this) { nativeTravelMode }
        val destination = resolveSharedEndpoint(share.destination, "Shared destination")
        if (destination.error != null) {
            failSharedRoute(share, destination.error)
            return
        }
        val targetEndpoint = destination.endpoint
            ?: run {
                failSharedRoute(
                    share,
                    SharedRouteFailure(ERROR_ROUTE_PROVIDER, "Shared destination could not be resolved.")
                )
                return
            }

        val cachedOrigin: NativeRouteEndpoint? = if (share.explicitOrigin) {
            val parsedOrigin = share.origin
                ?: run {
                    failSharedRoute(
                        share,
                        SharedRouteFailure(ERROR_ROUTE_PROVIDER, "Shared route origin is missing.")
                    )
                    return
                }
            val origin = resolveSharedEndpoint(parsedOrigin, "Shared origin")
            if (origin.error != null) {
                failSharedRoute(share, origin.error)
                return
            }
            val resolvedOrigin = origin.endpoint
            if (resolvedOrigin == null) {
                failSharedRoute(
                    share,
                    SharedRouteFailure(ERROR_ROUTE_PROVIDER, "Shared route origin could not be resolved.")
                )
                return
            }
            resolvedOrigin
        } else {
            null
        }

        emitShareStatus(
            state = "routeLoading",
            share = share,
            destinationLabel = targetEndpoint.label,
            originLabel = cachedOrigin?.label,
            detail = "Starting shared route."
        )

        val request = linkedMapOf<String, Any?>(
            "originPolicy" to if (share.explicitOrigin) ROUTE_ORIGIN_EXPLICIT_PLACE else ROUTE_ORIGIN_CURRENT_LOCATION,
            "destination" to nativeRouteEndpointMap(targetEndpoint),
            "travelMode" to requestedMode
        )
        cachedOrigin?.let { request["origin"] = nativeRouteEndpointMap(it) }
        watchRuntime.startNavigation(request) { outcome ->
            val state = outcome["deliveryState"] as? String ?: "deliveryFailed"
            val detail = outcome["detail"] as? String ?: "Shared route failed."
            val responses = outcome["responses"] as? List<*>
            val errorCategory = responses
                ?.asSequence()
                ?.mapNotNull { it as? Map<*, *> }
                ?.firstOrNull { intValue(it, KEY_CMD) == CMD_ERROR_STATE }
                ?.let { intValue(it, KEY_BUTTON_ID) }
            emitShareStatus(
                state = when (state) {
                    "applied" -> "activeRoute"
                    "timedOut", "queued" -> "queuedUnconfirmed"
                    "launchFailed" -> "launchFailed"
                    "protocolMismatch" -> "protocolMismatch"
                    else -> if (errorCategory == ERROR_NO_ROUTE) "noRoute" else "error"
                },
                share = share,
                destinationLabel = targetEndpoint.label,
                originLabel = cachedOrigin?.label,
                detail = detail,
                errorCategory = errorCategory
            )
            emitProviderStatusEvent()
            emitBridgeStatus()
        }
    }

    private fun nativeRouteEndpointMap(endpoint: NativeRouteEndpoint): Map<String, Any?> = mapOf(
        "label" to endpoint.label,
        "address" to endpoint.address,
        "latitude" to endpoint.latitude,
        "longitude" to endpoint.longitude,
        "placeId" to endpoint.placeId
    )

    private fun resolveSharedEndpoint(
        endpoint: GoogleMapsShareParser.Endpoint,
        fallbackLabel: String
    ): SharedEndpointResolution {
        val latitude = endpoint.latitude
        val longitude = endpoint.longitude
        if (latitude != null && longitude != null) {
            val label = firstNonBlank(endpoint.label, endpoint.address, fallbackLabel)
            return SharedEndpointResolution(
                NativeRouteEndpoint(
                    label = label,
                    address = firstNonBlank(endpoint.address, endpoint.label, label),
                    latitude = latitude,
                    longitude = longitude,
                    placeId = endpoint.placeId
                )
            )
        }

        val placeId = endpoint.placeId?.takeIf { it.isNotBlank() }
        if (placeId != null) {
            val resolved = try {
                mapTilesProvider.resolvePlace(
                    placeId = placeId,
                    sessionToken = null,
                    language = DEFAULT_LANGUAGE,
                    region = DEFAULT_REGION
                )
            } catch (_: Exception) {
                mapOf(
                    "ok" to false,
                    KEY_ERROR_CATEGORY to ERROR_ROUTE_PROVIDER,
                    "detail" to "Place resolution failed."
                )
            }
            if (resolved["ok"] == true) {
                endpointFromProviderResult(resolved, endpoint, fallbackLabel)?.let {
                    return SharedEndpointResolution(it)
                }
            }
            if (endpoint.address.isNullOrBlank() && endpoint.label.isNullOrBlank()) {
                return SharedEndpointResolution(
                    error = SharedRouteFailure(
                        category = intValue(resolved, KEY_ERROR_CATEGORY) ?: ERROR_ROUTE_PROVIDER,
                        detail = stringValue(resolved, "detail").ifBlank { "$fallbackLabel could not be resolved." }
                    )
                )
            }
        }

        val address = firstNonBlank(endpoint.address, endpoint.label).takeIf { it.isNotBlank() }
            ?: return SharedEndpointResolution(
                error = SharedRouteFailure(ERROR_ROUTE_PROVIDER, "$fallbackLabel is missing.")
            )
        val geocode = try {
            mapTilesProvider.geocodeDestination(
                addressText = address,
                language = DEFAULT_LANGUAGE,
                region = DEFAULT_REGION
            )
        } catch (_: Exception) {
            mapOf(
                "ok" to false,
                KEY_ERROR_CATEGORY to ERROR_ROUTE_PROVIDER,
                "detail" to "Geocoding failed."
            )
        }
        if (geocode["ok"] == true) {
            endpointFromProviderResult(geocode, endpoint, fallbackLabel)?.let {
                return SharedEndpointResolution(it)
            }
        }
        return SharedEndpointResolution(
            error = SharedRouteFailure(
                category = intValue(geocode, KEY_ERROR_CATEGORY) ?: ERROR_ROUTE_PROVIDER,
                detail = stringValue(geocode, "detail").ifBlank { "$fallbackLabel could not be resolved." }
            )
        )
    }

    private fun endpointFromProviderResult(
        result: Map<*, *>,
        sharedEndpoint: GoogleMapsShareParser.Endpoint,
        fallbackLabel: String
    ): NativeRouteEndpoint? {
        val latitude = doubleValue(result, "latitude") ?: return null
        val longitude = doubleValue(result, "longitude") ?: return null
        val label = firstNonBlank(
            sharedEndpoint.label,
            stringValue(result, "label"),
            stringValue(result, "formattedAddress"),
            sharedEndpoint.address,
            fallbackLabel
        )
        return NativeRouteEndpoint(
            label = label,
            address = firstNonBlank(
                stringValue(result, "formattedAddress"),
                sharedEndpoint.address,
                sharedEndpoint.label,
                label
            ),
            latitude = latitude,
            longitude = longitude,
            placeId = stringValue(result, "placeId").takeIf { it.isNotBlank() } ?: sharedEndpoint.placeId
        )
    }

    private fun failSharedRoute(share: GoogleMapsShareParser.Share, failure: SharedRouteFailure) {
        recordDiagnosticEntry(
            source = "google_maps_share",
            level = diagnosticLevel(failure.category),
            eventName = "share_route_failed",
            message = failure.detail,
            commandId = CMD_ROUTE_REQUEST,
            errorCategory = failure.category,
            shareType = share.type.channelName,
            safeUrlHost = share.safeHost,
            redirectHopCount = share.redirectHopCount,
            explicitOrigin = share.explicitOrigin,
            destinationHasCoordinates = share.destination.hasCoordinates,
            travelMode = shareTravelModeName(share)
        )
        queueNativePhoneMessage(
            errorMessage(
                category = failure.category,
                failedCommand = CMD_ROUTE_REQUEST,
                text = failure.detail
            )
        )
        emitShareStatus(
            state = if (failure.category == ERROR_NO_ROUTE) "noRoute" else "error",
            share = share,
            detail = failure.detail,
            errorCategory = failure.category
        )
        emitBridgeStatus()
    }

    private fun finishSharedRouteStatus(
        share: GoogleMapsShareParser.Share,
        targetEndpoint: NativeRouteEndpoint,
        cachedOrigin: NativeRouteEndpoint?
    ) {
        val error = synchronized(this) { nativeLastRouteError }
        if (error != null) {
            val category = intValue(error, "category") ?: ERROR_ROUTE_PROVIDER
            emitShareStatus(
                state = if (category == ERROR_NO_ROUTE) "noRoute" else "error",
                share = share,
                destinationLabel = targetEndpoint.label,
                originLabel = cachedOrigin?.label,
                detail = stringValue(error, "detail").ifBlank { "Shared route failed." },
                errorCategory = category
            )
            return
        }

        val summary = synchronized(this) { nativeActiveRouteSummary }
        emitShareStatus(
            state = "activeRoute",
            share = share,
            destinationLabel = targetEndpoint.label,
            originLabel = cachedOrigin?.label,
            detail = "Navigation to ${targetEndpoint.label} sent to watch.",
            distanceMeters = intValue(summary ?: emptyMap<String, Any?>(), "distanceMeters"),
            durationSeconds = intValue(summary ?: emptyMap<String, Any?>(), "durationSeconds"),
            routeWarning = stringValue(summary ?: emptyMap<String, Any?>(), "routeWarning").takeIf { it.isNotBlank() }
        )
    }

    private fun emitShareStatus(
        state: String,
        share: GoogleMapsShareParser.Share? = null,
        detail: String,
        safeHost: String? = share?.safeHost,
        destinationLabel: String? = share?.destination?.label,
        originLabel: String? = share?.origin?.label,
        errorCategory: Int? = null,
        distanceMeters: Int? = null,
        durationSeconds: Int? = null,
        routeWarning: String? = null
    ) {
        val payload = linkedMapOf<String, Any?>(
            "event" to "shareStatus",
            "timestampMillis" to System.currentTimeMillis(),
            "state" to state,
            "shareType" to share?.type?.channelName,
            "safeHost" to safeHost,
            "redirectHopCount" to share?.redirectHopCount,
            "explicitOrigin" to share?.explicitOrigin,
            "destinationHasCoordinates" to share?.destination?.hasCoordinates,
            "travelMode" to shareTravelModeName(share),
            "originLabel" to originLabel,
            "destinationLabel" to destinationLabel,
            "detail" to detail,
            "errorCategory" to errorCategory,
            "distanceMeters" to distanceMeters,
            "durationSeconds" to durationSeconds,
            "routeWarning" to routeWarning
        ).filterValues { it != null }
        synchronized(this) {
            nativeLastShareStatus = payload
        }
        emitBridgeEvent(payload)
    }

    private fun shareTravelModeName(share: GoogleMapsShareParser.Share?): String? =
        share?.travelMode?.channelName ?: share?.let {
            synchronized(this) {
                when (travelProtocolValue(nativeTravelMode)) {
                    0 -> "walk"
                    1 -> "bike"
                    else -> "drive"
                }
            }
        }

    private fun firstNonBlank(vararg values: String?): String =
        values.firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()

    private fun handleWatchBridgeEvent(event: Map<String, Any?>) {
        if (event["event"] == "transportChanged") {
            when (event["reason"] as? String) {
                "connected",
                "watchData" -> if (isGpsStreamingRequested()) {
                    startGpsStreamingIfPossible()
                }
                "disconnected",
                "stopped" -> stopGpsStreaming(sendError = false)
            }
            when (event["reason"] as? String) {
                "connected" -> recordDiagnosticEntry(
                    source = "android_bridge",
                    level = "info",
                    eventName = "watch_connected",
                    message = "Watch transport connected."
                )
                "disconnected",
                "stopped" -> recordDiagnosticEntry(
                    source = "android_bridge",
                    level = "warn",
                    eventName = "watch_disconnected",
                    message = "Watch transport disconnected."
                )
            }
        }
        if (event["event"] == "watchCommand") {
            val command = (event["command"] as? Number)?.toInt()
            val tileX = (event[KEY_WORLD_X] as? Number)?.toInt()
            val tileY = (event[KEY_WORLD_Y] as? Number)?.toInt()
            val tileZoom = (event[KEY_TILE_ZOOM] as? Number)?.toInt()
            if (command == CMD_LOG_EVENT) {
                nativeLogEvent(event)
            } else {
                recordDiagnosticEntry(
                    source = "pebble",
                    level = "info",
                    eventName = when (command) {
                        CMD_INIT -> "watch_init_received"
                        CMD_TILE_REQUEST -> "tile_request_received"
                        else -> "watch_command_received"
                    },
                    message = if (command == CMD_TILE_REQUEST) {
                        "Watch requested tile x=${tileX ?: 0} y=${tileY ?: 0} z=${tileZoom ?: 0}."
                    } else {
                        "Watch command ${command ?: 0} received."
                    },
                    commandId = command,
                    tileX = tileX,
                    tileY = tileY,
                    tileZoom = tileZoom
                )
            }
        }
        if (event["event"] == "sendResult") {
            val command = (event["command"] as? Number)?.toInt()
            val result = event["result"] as? String ?: "updated"
            val attempts = (event["attempts"] as? Number)?.toInt()
            recordDiagnosticEntry(
                source = "pebble",
                level = if (result == "ack") "info" else "warn",
                eventName = if (command == CMD_TILE) {
                    if (result == "ack") "tile_response_ack" else "tile_response_send_failed"
                } else if (result == "ack") {
                    "watch_send_ack"
                } else {
                    "watch_send_nack"
                },
                message = if (command == CMD_TILE) {
                    "Tile response send $result."
                } else {
                    "Watch send $result for command ${command ?: 0}."
                },
                commandId = command,
                tileX = (event[KEY_WORLD_X] as? Number)?.toInt(),
                tileY = (event[KEY_WORLD_Y] as? Number)?.toInt(),
                tileZoom = (event[KEY_TILE_ZOOM] as? Number)?.toInt(),
                attempt = attempts,
                tileWidth = (event[KEY_WIDTH] as? Number)?.toInt(),
                tileHeight = (event[KEY_HEIGHT] as? Number)?.toInt(),
                tileChunkIndex = (event[KEY_CHUNK_INDEX] as? Number)?.toInt(),
                tileChunkOffset = (event[KEY_CHUNK_OFFSET] as? Number)?.toInt(),
                tileTotalBytes = (event[KEY_TOTAL_BYTES] as? Number)?.toInt()
            )
        }
        if (event["event"] == "deliveryFailure") {
            val command = (event["command"] as? Number)?.toInt() ?: 0
            val result = event["result"] as? String ?: "failed"
            if (command == CMD_TILE) {
                recordTileDropDiagnostic(event, result)
            }
            emitDiagnosticEvent(
                source = "pebble",
                category = ERROR_ROUTE_PROVIDER,
                failedCommand = command,
                detail = "Watch delivery $result for command $command."
            )
        }
        if (event["event"] == "tileDrop") {
            val reason = event["reason"] as? String ?: "drop"
            recordTileDropDiagnostic(event, reason)
        }
        emitBridgeEvent(event)
        if (event["event"] != "bridgeStatus") {
            emitBridgeStatus()
        }
    }

    private fun recordTileDropDiagnostic(event: Map<String, Any?>, reason: String) {
        recordDiagnosticEntry(
            source = "tile_worker",
            level = "warn",
            eventName = "tile_response_dropped",
            message = "Tile response dropped by transport: $reason.",
            commandId = CMD_TILE,
            errorCategory = ERROR_TILE_PROVIDER,
            tileX = (event[KEY_WORLD_X] as? Number)?.toInt(),
            tileY = (event[KEY_WORLD_Y] as? Number)?.toInt(),
            tileZoom = (event[KEY_TILE_ZOOM] as? Number)?.toInt(),
            provider = "google_map_tiles",
            tileWidth = (event[KEY_WIDTH] as? Number)?.toInt(),
            tileHeight = (event[KEY_HEIGHT] as? Number)?.toInt(),
            tileChunkIndex = (event[KEY_CHUNK_INDEX] as? Number)?.toInt(),
            tileChunkOffset = (event[KEY_CHUNK_OFFSET] as? Number)?.toInt(),
            tileTotalBytes = (event[KEY_TOTAL_BYTES] as? Number)?.toInt(),
            tileReason = reason
        )
    }

    private fun emitBridgeStatus() {
        val payload = bridgeStatusPayload()
        recordSetupStateChanged(payload["setupState"] as? String)
        recordNotificationPermissionChanged(payload["notificationPermissionState"] as? String)
        emitBridgeEvent(payload)
    }

    private fun emitProviderStatusEvent(status: Map<String, Any?>? = null) {
        val providerStatus = status ?: try {
            mapTilesProvider.providerStatus()
        } catch (_: Exception) {
            mapOf(
                "configured" to false,
                "detail" to "Provider status unavailable."
            )
        }
        emitBridgeEvent(
            mapOf(
                "event" to "providerStatus",
                "providerStatus" to providerStatus
            )
        )
    }

    private fun emitLocationStatusEvent() {
        val status = gpsStreamingStatusPayload()
        recordLocationPermissionChanged(status["permissionState"] as? String)
        emitBridgeEvent(
            mapOf(
                "event" to "locationStatus",
                "locationStream" to status
            )
        )
    }

    private fun recordSetupStateChanged(setupState: String?) {
        val state = setupState?.takeIf { it.isNotBlank() } ?: return
        val changed = synchronized(this) {
            if (lastEmittedSetupState == state) {
                false
            } else {
                lastEmittedSetupState = state
                true
            }
        }
        if (!changed) {
            return
        }
        recordDiagnosticEntry(
            source = "android_bridge",
            level = "info",
            eventName = "setup_state_changed",
            message = "Setup state changed to $state.",
            setupState = state
        )
    }

    private fun recordLocationPermissionChanged(permissionState: String?) {
        val state = permissionState?.takeIf { it.isNotBlank() } ?: return
        val changed = synchronized(this) {
            if (lastEmittedPermissionState == state) {
                false
            } else {
                lastEmittedPermissionState = state
                true
            }
        }
        if (!changed) {
            return
        }
        recordDiagnosticEntry(
            source = "location",
            level = "info",
            eventName = "location_permission_changed",
            message = "Location permission state changed to $state."
        )
    }

    private fun recordNotificationPermissionChanged(permissionState: String?) {
        val state = permissionState?.takeIf { it.isNotBlank() } ?: return
        val changed = synchronized(this) {
            if (lastEmittedNotificationPermissionState == state) {
                false
            } else {
                lastEmittedNotificationPermissionState = state
                true
            }
        }
        if (!changed) {
            return
        }
        recordDiagnosticEntry(
            source = "android_bridge",
            level = "info",
            eventName = "notification_permission_changed",
            message = "Notification permission state changed to $state."
        )
    }

    private fun recordLocationFixUpdated(location: Location, source: String = "location") {
        val orientation = orientationName(nativeMapOrientation)
        val hasHeading = location.hasBearing()
        recordDiagnosticEntry(
            source = source,
            level = "info",
            eventName = "location_fix_updated",
            message = "Location fix updated.",
            mapOrientation = orientation,
            headingSource = if (hasHeading) "phone_course" else "none"
        )
    }

    private fun recordMapOrientationChanged(source: String, orientation: Int) {
        recordDiagnosticEntry(
            source = source,
            level = "info",
            eventName = "map_orientation_changed",
            message = "Map orientation changed to ${orientationName(orientation)}.",
            commandId = CMD_MAP_ORIENTATION,
            mapOrientation = orientationName(orientation),
            headingSource = diagnosticsHeadingSource(),
            orientationFallback = diagnosticsOrientationFallback()
        )
    }

    private fun emitDiagnosticEvent(
        source: String,
        category: Int,
        failedCommand: Int,
        detail: String,
        eventName: String? = null,
        watchDetail: Int? = null,
        watchDetail2: Int? = null
    ) {
        val id = nextDiagnosticId()
        val message = redactDiagnosticMessage(detail)
        val timestampWallMillis = System.currentTimeMillis()
        val event = eventName ?: diagnosticEventName(source, category, failedCommand)
        val watchStatus = watchStatusPayload()
        val storedPayload = linkedMapOf<String, Any?>(
            "id" to id,
            "timestamp_wall_ms" to timestampWallMillis,
            "timestamp_mono_ms" to SystemClock.elapsedRealtime(),
            "source" to source,
            "level" to diagnosticLevel(category),
            "event" to event,
            "message" to message,
            "command_id" to failedCommand.takeIf { it > 0 },
            "error_category" to category.takeIf { it != 0 },
            "watch_detail" to watchDetail,
            "watch_detail2" to watchDetail2,
            "watch_connected" to (watchStatus["watchConnected"] == true),
            "watch_ready" to (watchStatus["watchReady"] == true)
        ).filterValues { it != null }
        val payload = linkedMapOf(
            "event" to "diagnosticEvent",
            "eventId" to "native-$id",
            "severity" to diagnosticLevel(category),
            "source" to source,
            "message" to message,
            "category" to category,
            "failedCommand" to failedCommand,
            "detail" to message,
            "timestampMillis" to timestampWallMillis
        )
        recordDiagnosticEvent(storedPayload)
        emitBridgeEvent(payload)
    }

    private fun recordDiagnosticEntry(
        source: String,
        level: String,
        eventName: String,
        message: String,
        commandId: Int? = null,
        errorCategory: Int? = null,
        tileX: Int? = null,
        tileY: Int? = null,
        tileZoom: Int? = null,
        savedLocationSlot: Int? = null,
        routeOriginId: String? = null,
        routeTargetId: String? = null,
        provider: String? = null,
        providerErrorClass: String? = null,
        attempt: Int? = null,
        watchDetail: Int? = null,
        watchDetail2: Int? = null,
        httpStatus: Int? = null,
        setupState: String? = null,
        mapOrientation: String? = null,
        headingSource: String? = null,
        orientationFallback: String? = null,
        tileWidth: Int? = null,
        tileHeight: Int? = null,
        tileChunkIndex: Int? = null,
        tileChunkOffset: Int? = null,
        tileTotalBytes: Int? = null,
        tileSource: String? = null,
        tileReason: String? = null,
        shareType: String? = null,
        safeUrlHost: String? = null,
        redirectHopCount: Int? = null,
        explicitOrigin: Boolean? = null,
        destinationHasCoordinates: Boolean? = null,
        travelMode: String? = null
    ) {
        val watchStatus = watchStatusPayload()
        val event = linkedMapOf<String, Any?>(
            "id" to nextDiagnosticId(),
            "timestamp_wall_ms" to System.currentTimeMillis(),
            "timestamp_mono_ms" to SystemClock.elapsedRealtime(),
            "source" to source,
            "level" to level,
            "event" to eventName,
            "message" to redactDiagnosticMessage(message),
            "command_id" to commandId,
            "error_category" to errorCategory,
            "tile_x" to tileX,
            "tile_y" to tileY,
            "tile_zoom" to tileZoom,
            "saved_location_slot" to savedLocationSlot,
            "route_origin_id" to routeOriginId,
            "route_target_id" to routeTargetId,
            "provider" to provider,
            "provider_error_class" to providerErrorClass,
            "attempt" to attempt,
            "watch_detail" to watchDetail,
            "watch_detail2" to watchDetail2,
            "http_status" to httpStatus,
            "watch_connected" to (watchStatus["watchConnected"] == true),
            "watch_ready" to (watchStatus["watchReady"] == true),
            "setup_state" to setupState,
            "map_orientation" to mapOrientation,
            "heading_source" to headingSource,
            "orientation_fallback" to orientationFallback,
            "tile_width" to tileWidth,
            "tile_height" to tileHeight,
            "tile_chunk_index" to tileChunkIndex,
            "tile_chunk_offset" to tileChunkOffset,
            "tile_total_bytes" to tileTotalBytes,
            "tile_source" to tileSource,
            "tile_reason" to tileReason,
            "share_type" to shareType,
            "safe_url_host" to safeUrlHost,
            "redirect_hop_count" to redirectHopCount,
            "explicit_origin" to explicitOrigin,
            "destination_has_coordinates" to destinationHasCoordinates,
            "travel_mode" to travelMode
        ).filterValues { it != null }
        recordDiagnosticEvent(event)
    }

    private fun nextDiagnosticId(): Int =
        synchronized(this) {
            val value = nextDiagnosticEventId
            nextDiagnosticEventId = if (nextDiagnosticEventId == Int.MAX_VALUE) {
                1
            } else {
                nextDiagnosticEventId + 1
            }
            value
        }

    private fun diagnosticLevel(category: Int): String =
        when (category) {
            0 -> "info"
            ERROR_NO_ROUTE,
            ERROR_LOCATION_UNAVAILABLE -> "warn"
            else -> "error"
        }

    private fun diagnosticEventName(source: String, category: Int, commandId: Int): String =
        when {
            source == "watch" && category == 0 -> "watch_log_event"
            source == "watch" -> "watch_log_error"
            source == "pebble" -> "watch_send_nack"
            source == "location" && category == ERROR_LOCATION_UNAVAILABLE -> "location_stale"
            commandId > 0 -> "error_state_sent"
            else -> "watch_command_received"
        }

    private fun redactDiagnosticMessage(message: String): String =
        redactDiagnosticCredentials(message, diagnosticRedactionSecrets())

    private fun diagnosticRedactionSecrets(): List<String> =
        try {
            if (::apiKeyStore.isInitialized) {
                listOfNotNull(apiKeyStore.getPlaintextKey())
                    .filter { it.isNotBlank() }
            } else {
                emptyList()
            }
        } catch (_: Exception) {
            emptyList()
        }

    private fun redactDiagnosticValue(value: Any?): Any? =
        when (value) {
            is String -> redactDiagnosticMessage(value)
            is Map<*, *> -> value.entries.associate { (key, item) ->
                key.toString() to redactDiagnosticValue(item)
            }
            is Iterable<*> -> value.map { redactDiagnosticValue(it) }
            is Array<*> -> value.map { redactDiagnosticValue(it) }
            else -> value
        }

    private fun redactDiagnosticMap(value: Map<String, Any?>): Map<String, Any?> =
        value.mapValues { (_, item) -> redactDiagnosticValue(item) }

    private fun recordDiagnosticEvent(event: Map<String, Any?>) {
        //synchronized(this) {
        //    nativeDiagnosticEvents.addLast(LinkedHashMap(redactStoredDiagnosticEvent(event)))
        //    trimDiagnosticEventsLocked()
        //    persistDiagnosticEventsLocked()
        //}
    }

    private fun exportDiagnosticsPayload(): Map<String, Any?> {
        val events = synchronized(this) {
            nativeDiagnosticEvents.map { redactStoredDiagnosticEvent(it) }
        }
        return redactDiagnosticMap(
            linkedMapOf(
                "schema_version" to 1,
                "created_at" to isoTimestamp(System.currentTimeMillis()),
                "app_package" to packageName,
                "app_version" to BuildConfig.VERSION_NAME,
                "watch_uuid" to WATCH_APP_UUID.toString(),
                "redaction" to mapOf(
                    "full_keys" to "redacted",
                    "location" to "default"
                ),
                "status" to diagnosticsStatusSnapshot(),
                "events" to events
            )
        )
    }

    private fun writeDiagnosticsExportFile(payload: Map<String, Any?>): Map<String, Any?> =
        try {
            val directory = File(cacheDir, "diagnostics")
            directory.mkdirs()
            val filename = "mappy-diagnostics-${diagnosticsFileTimestamp()}.json"
            val file = File(directory, filename)
            file.writeText(JSONObject(payload).toString(2), Charsets.UTF_8)
            mapOf(
                "file_name" to filename,
                "file_path" to file.absolutePath,
                "file_uri" to file.toURI().toString(),
                "mime_type" to "application/json"
            )
        } catch (_: Exception) {
            mapOf(
                "file_error" to "Diagnostics export file could not be written."
            )
        }

    private fun diagnosticsFileTimestamp(): String {
        val formatter = SimpleDateFormat("yyyyMMdd-HHmmss", Locale.US)
        formatter.timeZone = TimeZone.getTimeZone("UTC")
        return formatter.format(Date())
    }

    private fun diagnosticsStatusSnapshot(): Map<String, Any?> {
        val bridge = bridgeStatusPayload()
        val destinationCount = synchronized(this) { nativeDestinations.size }
        val lastError = synchronized(this) { lastSafeErrorCategory to lastSafeErrorText }
        return bridge + mapOf(
            "saved_location_count" to destinationCount,
            "map_orientation" to orientationName(nativeMapOrientation),
            "heading_source" to diagnosticsHeadingSource(),
            "orientation_fallback" to diagnosticsOrientationFallback(),
            "last_error_category" to lastError.first,
            "last_error_text" to lastError.second
        ).filterValues { it != null }
    }

    private fun clearDiagnosticEvents() {
        synchronized(this) {
            nativeDiagnosticEvents.clear()
            persistDiagnosticEventsLocked()
        }
        emitDiagnosticEvent(
            source = "flutter",
            category = 0,
            failedCommand = 0,
            detail = "Diagnostics cleared.",
            eventName = "diagnostics_cleared"
        )
        emitBridgeStatus()
    }

    private fun clearNativeRouteCache(
        recordDiagnostic: Boolean = true,
        source: String = "flutter"
    ) {
        synchronized(this) {
            nativeRouteGeneration += 1
            clearActiveRouteLocked()
        }
        if (recordDiagnostic) {
            recordDiagnosticEntry(
                source = source,
                level = "info",
                eventName = "cache_cleared",
                message = "Route cache cleared.",
                commandId = CMD_ROUTE_CLEAR
            )
        }
        emitBridgeStatus()
    }

    private fun loadDiagnosticEvents() {
        val raw = getSharedPreferences(DIAGNOSTIC_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .getString(DIAGNOSTIC_PREFERENCES_KEY, null)
            ?: return
        val events = try {
            val json = JSONArray(raw)
            buildList {
                for (index in 0 until json.length()) {
                    add(jsonObjectToMap(json.optJSONObject(index) ?: continue))
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
        synchronized(this) {
            nativeDiagnosticEvents.clear()
            events.forEach { nativeDiagnosticEvents.addLast(normalizeStoredDiagnosticEvent(it)) }
            trimDiagnosticEventsLocked()
            val nextId = nativeDiagnosticEvents
                .asSequence()
                .mapNotNull { (it["id"] as? Number)?.toInt() }
                .maxOrNull()
                ?.let { if (it == Int.MAX_VALUE) 1 else it + 1 }
            if (nextId != null) {
                nextDiagnosticEventId = nextId
            }
        }
    }

    private fun persistDiagnosticEventsLocked() {
        val json = diagnosticEventsJsonLocked()
        getSharedPreferences(DIAGNOSTIC_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(DIAGNOSTIC_PREFERENCES_KEY, json.toString())
            .apply()
    }

    private fun diagnosticEventsJsonLocked(): JSONArray {
        val json = JSONArray()
        nativeDiagnosticEvents.forEach { event ->
            json.put(JSONObject(redactStoredDiagnosticEvent(event)))
        }
        return json
    }

    private fun trimDiagnosticEventsLocked() {
        while (nativeDiagnosticEvents.size > MAX_DIAGNOSTIC_EVENTS) {
            nativeDiagnosticEvents.removeFirst()
        }
        while (
            nativeDiagnosticEvents.isNotEmpty() &&
            diagnosticEventsJsonLocked().toString().toByteArray(Charsets.UTF_8).size >
                MAX_DIAGNOSTIC_BYTES
        ) {
            nativeDiagnosticEvents.removeFirst()
        }
    }

    private fun normalizeStoredDiagnosticEvent(event: Map<String, Any?>): Map<String, Any?> {
        val id = numberValue(event["id"])?.toInt()
            ?: (event["eventId"] as? String)?.removePrefix("native-")?.toIntOrNull()
            ?: nextDiagnosticId()
        val category = numberValue(event["error_category"])?.toInt()
            ?: numberValue(event["category"])?.toInt()
            ?: 0
        val commandId = numberValue(event["command_id"])?.toInt()
            ?: numberValue(event["failedCommand"])?.toInt()
            ?: 0
        val source = stringValue(event["source"]).ifBlank { "android_bridge" }
        val message = redactDiagnosticMessage(
            stringValue(event["message"]).ifBlank { stringValue(event["detail"]) }
        )
        val storedEvent = stringValue(event["event"]).let { value ->
            if (value.isBlank() || value == "diagnosticEvent") {
                diagnosticEventName(source, category, commandId)
            } else {
                value
            }
        }
        return linkedMapOf(
            "id" to id,
            "timestamp_wall_ms" to (
                numberValue(event["timestamp_wall_ms"])?.toLong()
                    ?: numberValue(event["timestampMillis"])?.toLong()
                    ?: System.currentTimeMillis()
                ),
            "timestamp_mono_ms" to numberValue(event["timestamp_mono_ms"])?.toLong(),
            "source" to source,
            "level" to stringValue(event["level"]).ifBlank {
                stringValue(event["severity"]).ifBlank { diagnosticLevel(category) }
            }.let { if (it == "warning") "warn" else it },
            "event" to storedEvent,
            "message" to message,
            "correlation_id" to stringValue(event["correlation_id"]).takeIf { it.isNotBlank() },
            "command_id" to commandId.takeIf { it > 0 },
            "error_category" to category.takeIf { it != 0 },
            "tile_x" to numberValue(event["tile_x"])?.toInt(),
            "tile_y" to numberValue(event["tile_y"])?.toInt(),
            "tile_zoom" to numberValue(event["tile_zoom"])?.toInt(),
            "route_origin_id" to stringValue(event["route_origin_id"]).takeIf { it.isNotBlank() },
            "route_target_id" to stringValue(event["route_target_id"]).takeIf { it.isNotBlank() },
            "saved_location_slot" to numberValue(event["saved_location_slot"])?.toInt(),
            "route_id" to stringValue(event["route_id"]).takeIf { it.isNotBlank() },
            "http_status" to numberValue(event["http_status"])?.toInt(),
            "provider" to stringValue(event["provider"]).takeIf { it.isNotBlank() },
            "provider_error_class" to stringValue(event["provider_error_class"]).takeIf { it.isNotBlank() },
            "attempt" to numberValue(event["attempt"])?.toInt(),
            "watch_detail" to numberValue(event["watch_detail"])?.toInt(),
            "watch_detail2" to numberValue(event["watch_detail2"])?.toInt(),
            "watch_connected" to boolValue(event["watch_connected"]),
            "watch_ready" to boolValue(event["watch_ready"]),
            "setup_state" to stringValue(event["setup_state"]).takeIf { it.isNotBlank() },
            "map_orientation" to stringValue(event["map_orientation"]).takeIf { it.isNotBlank() },
            "heading_source" to stringValue(event["heading_source"]).takeIf { it.isNotBlank() },
            "orientation_fallback" to stringValue(event["orientation_fallback"]).takeIf { it.isNotBlank() }
        ).filterValues { it != null }
    }

    private fun redactStoredDiagnosticEvent(event: Map<String, Any?>): Map<String, Any?> =
        redactDiagnosticMap(event)

    private fun emitBridgeEvent(event: Map<String, Any?>) {
        val payload = LinkedHashMap<String, Any?>()
        payload.putAll(event)
        if (!payload.containsKey("timestampMillis")) {
            payload["timestampMillis"] = System.currentTimeMillis()
        }
        mainHandler.post {
            bridgeEventSink?.success(payload)
        }
    }

    private fun bridgeStatusPayload(): Map<String, Any?> {
        val watchStatus = watchStatusPayload()
        val providerStatus = try {
            mapTilesProvider.providerStatus()
        } catch (_: Exception) {
            mapOf(
                "configured" to false,
                "detail" to "Provider status unavailable."
            )
        }
        val permission = permissionState()
        return linkedMapOf(
            "event" to "bridgeStatus",
            "timestampMillis" to System.currentTimeMillis(),
            "registered" to (watchStatus["registered"] == true),
            "watchReady" to (watchStatus["watchReady"] == true),
            "watchConnected" to (watchStatus["watchConnected"] == true),
            "watchAppActive" to (watchStatus["watchAppActive"] == true),
            "foregroundServiceActive" to WatchSessionForegroundService.isActive,
            "foregroundServiceLastError" to WatchSessionForegroundService.lastStartError(),
            "queueLength" to (watchStatus["queueLength"] as? Number ?: 0).toInt(),
            "inFlight" to (watchStatus["inFlight"] == true),
            "setupState" to bridgeSetupState(providerStatus, permission),
            "permissionState" to permission,
            "notificationPermissionState" to notificationPermissionState(),
            "providerStatus" to providerStatus,
            "locationStream" to gpsStreamingStatusPayload(),
            "diagnosticCount" to synchronized(this) { nativeDiagnosticEvents.size },
            "watch" to watchStatus
        )
    }

    private fun gpsStreamingStatusPayload(): Map<String, Any?> =
        WatchLocationStreamer.status(this, permissionState())

    private fun watchStatusPayload(): Map<String, Any?> =
        if (::watchRuntime.isInitialized) watchRuntime.status() else mapOf(
            "registered" to false,
            "watchReady" to false,
            "watchConnected" to false,
            "watchAppActive" to false,
            "queueLength" to 0,
            "inFlight" to false
        )

    private fun orientationName(value: Int): String =
        if (value == 1) "forward_up" else "north_up"

    private fun diagnosticsHeadingSource(): String {
        return if (nativeMapOrientation == 1) {
            "watch_compass"
        } else {
            "none"
        }
    }

    private fun diagnosticsOrientationFallback(): String? {
        return null
    }

    private fun bridgeSetupState(providerStatus: Map<String, Any?>, permission: String): String =
        when {
            providerStatus["configured"] != true -> "providerRequired"
            providerStatus["validationState"] != "valid" -> "providerRequired"
            permission !in setOf(
                "grantedPrecise",
                "grantedApproximate",
                "grantedAlwaysPrecise",
                "grantedAlwaysApproximate"
            ) -> "locationRequired"
            else -> "ready"
        }

    private fun dispatchWatchMessage(message: Map<*, *>): List<Map<String, Any?>> =
        try {
            handleWatchMessage(message, includePendingMessages = false)
        } catch (_: Exception) {
            listOf(
                errorMessage(
                    category = ERROR_ROUTE_PROVIDER,
                    failedCommand = intValue(message, KEY_CMD) ?: 0,
                    text = "Watch dispatcher task failed."
                )
            )
        }

    private fun handleWatchMessage(
        message: Map<*, *>,
        includePendingMessages: Boolean = true
    ): List<Map<String, Any?>> {
        val command = intValue(message, KEY_CMD)
        recordWatchRequestDiagnostic(command, message)
        val directResponses = when (command) {
            CMD_INIT -> nativeInit()
            CMD_TILE_REQUEST -> nativeTileRequest(message)
            CMD_BUTTON -> emptyList()
            CMD_ROUTE_REQUEST -> nativeRouteRequest(message)
            CMD_ROUTE_WINDOW_REQUEST -> nativeRouteWindowRequest(message)
            CMD_NAV_STEPS -> nativeNavSteps(message)
            CMD_ROUTE_CLEAR -> {
                clearNativeRouteCache(recordDiagnostic = true, source = "android_bridge")
                listOf(watchMessage(CMD_ROUTE_CLEAR))
            }
            CMD_THEME -> {
                nativeThemeMode = themeProtocolValue(intValue(message, KEY_BUTTON_ID))
                saveDisplaySettings()
                listOf(
                    watchMessage(CMD_THEME, mapOf(KEY_BUTTON_ID to nativeThemeMode)),
                    mapSettingsMessage(reason = 4)
                )
            }
            CMD_TRAVEL_MODE -> {
                nativeTravelMode = travelProtocolValue(intValue(message, KEY_BUTTON_ID))
                saveDisplaySettings()
                listOf(watchMessage(CMD_TRAVEL_MODE, mapOf(KEY_BUTTON_ID to nativeTravelMode)))
            }
            CMD_UNITS -> {
                nativeUnitsMode = unitsProtocolValue(intValue(message, KEY_BUTTON_ID))
                saveDisplaySettings()
                listOf(unitsMessage())
            }
            CMD_BACKLIGHT -> {
                nativeBacklightMode = backlightProtocolValue(intValue(message, KEY_BUTTON_ID))
                saveDisplaySettings()
                listOf(backlightMessage())
            }
            CMD_MAP_ORIENTATION -> {
                val previous = nativeMapOrientation
                nativeMapOrientation = mapOrientationProtocolValue(intValue(message, KEY_BUTTON_ID))
                saveDisplaySettings()
                if (previous != nativeMapOrientation) {
                    recordMapOrientationChanged("watch", nativeMapOrientation)
                }
                listOf(mapOrientationMessage())
            }
            CMD_TILE_ANIMATION -> {
                nativeTileAnimationMode = tileAnimationProtocolValue(intValue(message, KEY_BUTTON_ID))
                saveDisplaySettings()
                listOf(tileAnimationMessage())
            }
            CMD_LOG_EVENT -> {
                nativeLogEvent(message)
                emptyList()
            }
            else -> listOf(
                errorMessage(
                    category = ERROR_ROUTE_PROVIDER,
                    failedCommand = intValue(message, KEY_CMD) ?: 0,
                    text = "Unsupported watch command."
                )
            )
        }
        val queuedMessages = if (includePendingMessages) drainNativePhoneMessages() else emptyList()
        return if (queuedMessages.isEmpty()) {
            directResponses
        } else {
            queuedMessages + directResponses
        }
    }

    private fun recordWatchRequestDiagnostic(command: Int?, message: Map<*, *>) {
        when (command) {
            CMD_TILE_REQUEST -> return
            CMD_ROUTE_REQUEST -> recordDiagnosticEntry(
                source = "route_worker",
                level = "info",
                eventName = "route_request_received",
                message = "Route request received.",
                commandId = CMD_ROUTE_REQUEST,
                savedLocationSlot = intValue(message, KEY_BUTTON_ID)
            )
            CMD_ROUTE_WINDOW_REQUEST -> recordDiagnosticEntry(
                source = "route_worker",
                level = "info",
                eventName = "route_window_request_received",
                message = "Route detail window request received.",
                commandId = CMD_ROUTE_WINDOW_REQUEST,
                tileX = intValue(message, KEY_WORLD_X),
                tileY = intValue(message, KEY_WORLD_Y),
                tileZoom = intValue(message, KEY_TILE_ZOOM)
            )
            CMD_NAV_STEPS -> recordDiagnosticEntry(
                source = "pebble",
                level = "info",
                eventName = "watch_command_received",
                message = "Nav-step chunk request received.",
                commandId = CMD_NAV_STEPS
            )
        }
    }

    private fun nativeLogEvent(message: Map<*, *>) {
        val category = intValue(message, KEY_BUTTON_ID) ?: ERROR_ROUTE_PROVIDER
        val detailCode = intValue(message, KEY_CHUNK_OFFSET)
        val secondaryDetail = intValue(message, KEY_CHUNK_INDEX)
        val text = stringValue(message, KEY_INSTRUCTION).ifBlank {
            "Watch diagnostic category $category."
        }
        val detailSuffix = listOfNotNull(detailCode, secondaryDetail)
            .joinToString(", ")
            .takeIf { it.isNotBlank() }
            ?.let { " ($it)" }
            .orEmpty()
        val detail = "$text$detailSuffix"
        val eventName = watchLogEventName(text, category)
        emitDiagnosticEvent(
            source = "watch",
            category = category,
            failedCommand = CMD_LOG_EVENT,
            detail = detail,
            eventName = eventName,
            watchDetail = detailCode,
            watchDetail2 = secondaryDetail
        )
    }

    private fun watchLogEventName(text: String, category: Int): String {
        val normalized = text.lowercase()
        return when {
            normalized.contains("pinch unavailable") -> "pinch_unavailable"
            normalized.contains("touch disabled") -> "touch_disabled"
            normalized.contains("zoom clamped") -> "zoom_clamped"
            normalized.contains("walking detected") -> "motion_walking_detected"
            normalized.contains("watch look detected") -> "motion_watch_look_detected"
            normalized.contains("bearing reacquire") -> "bearing_reacquire_started"
            category == 0 -> "watch_log_event"
            else -> "watch_log_error"
        }
    }

    private fun queueNativePhoneMessage(message: Map<*, *>) {
        val fields = stringKeyMap(message)
        synchronized(this) {
            nativePendingPhoneMessages.add(fields)
        }
        watchRuntime.enqueue(fields)
    }

    private fun stringKeyMap(message: Map<*, *>): Map<String, Any?> =
        linkedMapOf<String, Any?>().apply {
            message.forEach { (key, value) ->
                if (key != null) {
                    put(key.toString(), value)
                }
            }
        }

    private fun drainNativePhoneMessages(): List<Map<String, Any?>> =
        synchronized(this) {
            if (nativePendingPhoneMessages.isEmpty()) {
                emptyList()
            } else {
                nativePendingPhoneMessages.toList().also {
                    nativePendingPhoneMessages.clear()
                }
            }
        }

    private fun nativeInit(): List<Map<String, Any?>> {
        saveDisplaySettings()
        requestGpsStreaming()

        val responses = mutableListOf(
            themeMessage(),
            travelModeMessage(),
            unitsMessage(),
            backlightMessage(),
            mapSettingsMessage(reason = 0),
            mapOrientationMessage(),
            tileAnimationMessage(),
            destinationsMessage()
        )

        val providerStatus = mapTilesProvider.providerStatus()
        if (providerStatus["configured"] != true) {
            responses.add(
                errorMessage(
                    category = ERROR_MISSING_KEY,
                    failedCommand = CMD_INIT,
                    text = "Missing Google API key."
                )
            )
        }

        val location = latestNativeLocation(requestIfStale = false)
        responses.add(
            if (location == null) {
                errorMessage(
                    category = ERROR_LOCATION_UNAVAILABLE,
                    failedCommand = CMD_GPS,
                    text = "No current location fix."
                )
            } else {
                WatchLocationStreamer.gpsMessageFor(location)
            }
        )
        activeRouteMessages().forEach { responses.add(it) }
        return responses
    }

    private fun nativeTileRequest(message: Map<*, *>): List<Map<String, Any?>> {
        val worldX = intValue(message, KEY_WORLD_X)
        val worldY = intValue(message, KEY_WORLD_Y)
        val zoom = intValue(message, KEY_TILE_ZOOM)
        val themeMode = themeProtocolValue(intValue(message, KEY_IS_COLOR) ?: nativeThemeMode)
        if (worldX == null || worldY == null || zoom == null) {
            recordTileFailureDiagnostic(
                source = "tile_worker",
                level = "error",
                eventName = "tile_response_dropped",
                message = "Tile request missing x, y, or zoom.",
                commandId = CMD_TILE_REQUEST,
                errorCategory = ERROR_TILE_PROVIDER,
                tileX = worldX,
                tileY = worldY,
                tileZoom = zoom,
                provider = "google_map_tiles"
            )
            return listOf(
                errorMessage(
                    category = ERROR_TILE_PROVIDER,
                    failedCommand = CMD_TILE_REQUEST,
                    text = "Tile request missing x, y, or zoom."
                )
            )
        }

        val tile = mapTilesProvider.watchTile(worldX, worldY, zoom, themeMode)
        if (tile["ok"] == true) {
            val chunkData = byteArrayValue(tile[KEY_CHUNK_DATA])
            if (chunkData != null) {
                val tileWidth = intValue(tile, KEY_WIDTH) ?: mapTilesProvider.currentMapTileSettings().watchTileWidth
                val tileHeight = intValue(tile, KEY_HEIGHT) ?: mapTilesProvider.currentMapTileSettings().watchTileHeight
                val totalBytes = intValue(tile, KEY_TOTAL_BYTES) ?: chunkData.size
                val tileSource = tile["tile_source"] as? String ?: "unknown"
                recordDiagnosticEntry(
                    source = "tile_worker",
                    level = "info",
                    eventName = "tile_response_ready",
                    message = "Tile response ready from $tileSource.",
                    commandId = CMD_TILE,
                    tileX = intValue(tile, KEY_WORLD_X) ?: worldX,
                    tileY = intValue(tile, KEY_WORLD_Y) ?: worldY,
                    tileZoom = intValue(tile, KEY_TILE_ZOOM) ?: zoom,
                    provider = "google_map_tiles",
                    tileWidth = tileWidth,
                    tileHeight = tileHeight,
                    tileTotalBytes = totalBytes,
                    tileSource = tileSource
                )
                return chunkData.asList()
                    .chunked(MAX_WATCH_TILE_CHUNK_BYTES)
                    .mapIndexed { chunkIndex, chunk ->
                        val chunkOffset = chunkIndex * MAX_WATCH_TILE_CHUNK_BYTES
                        watchMessage(
                            CMD_TILE,
                            mapOf(
                                KEY_WORLD_X to (intValue(tile, KEY_WORLD_X) ?: worldX),
                                KEY_WORLD_Y to (intValue(tile, KEY_WORLD_Y) ?: worldY),
                                KEY_TILE_ZOOM to (intValue(tile, KEY_TILE_ZOOM) ?: zoom),
                                KEY_WIDTH to tileWidth,
                                KEY_HEIGHT to tileHeight,
                                KEY_TOTAL_BYTES to totalBytes,
                                KEY_CHUNK_INDEX to chunkIndex,
                                KEY_CHUNK_OFFSET to chunkOffset,
                                KEY_CHUNK_DATA to chunk.toByteArray()
                            )
                        )
                    }
            }
        }

        val category = intValue(tile, KEY_ERROR_CATEGORY) ?: ERROR_TILE_PROVIDER
        val detail = tile["detail"] as? String ?: "Watch tile provider failed."
        val httpStatus = providerHttpStatus(tile)
        recordTileFailureDiagnostic(
            source = "tile_worker",
            level = "error",
            eventName = "tile_response_dropped",
            message = detail,
            commandId = CMD_TILE_REQUEST,
            errorCategory = category,
            tileX = worldX,
            tileY = worldY,
            tileZoom = zoom,
            provider = "google_map_tiles",
            httpStatus = httpStatus
        )
        return listOf(
            errorMessage(
                category = category,
                failedCommand = CMD_TILE_REQUEST,
                text = detail,
                worldX = worldX,
                worldY = worldY,
                zoom = zoom
            )
        )
    }

    private fun recordTileFailureDiagnostic(
        source: String,
        level: String,
        eventName: String,
        message: String,
        commandId: Int,
        errorCategory: Int,
        tileX: Int?,
        tileY: Int?,
        tileZoom: Int?,
        provider: String,
        httpStatus: Int? = null
    ) {
        val now = SystemClock.elapsedRealtime()
        val shouldRecord = synchronized(this) {
            if (now - lastTileFailureDiagnosticAtMillis >= TILE_DIAGNOSTIC_INTERVAL_MILLIS) {
                lastTileFailureDiagnosticAtMillis = now
                true
            } else {
                false
            }
        }
        if (!shouldRecord) {
            return
        }
        recordDiagnosticEntry(
            source = source,
            level = level,
            eventName = eventName,
            message = message,
            commandId = commandId,
            errorCategory = errorCategory,
            tileX = tileX,
            tileY = tileY,
            tileZoom = tileZoom,
            provider = provider,
            httpStatus = httpStatus
        )
    }

    private fun nativeRouteRequest(message: Map<*, *>): List<Map<String, Any?>> {
        val slot = intValue(message, KEY_BUTTON_ID)
        val requestedMode = travelProtocolValue(intValue(message, KEY_IS_COLOR) ?: nativeTravelMode)
        if (slot == null || !isSavedDestinationId(slot)) {
            return nativeActiveRouteReroute(
                requestedMode = requestedMode,
                requestSlot = slot
            )
        }

        val destination = synchronized(this) {
            nativeDestinations.firstOrNull { it.slot == slot }
        }
        if (destination == null) {
            return listOf(
                errorMessage(
                    category = ERROR_DESTINATION_NOT_CONFIGURED,
                    failedCommand = CMD_ROUTE_REQUEST,
                    text = "Destination not configured.",
                    offset = slot
                )
            )
        }

        val location = latestNativeLocation(ROUTE_LOCATION_FRESH_MILLIS)
        if (location == null) {
            return listOf(
                errorMessage(
                    category = ERROR_LOCATION_UNAVAILABLE,
                    failedCommand = CMD_ROUTE_REQUEST,
                    text = "Waiting for GPS.",
                    offset = slot
                )
            )
        }

        val targetEndpoint = nativeRouteEndpoint(destination)
        val generation = synchronized(this) {
            beginActiveRouteRequestLocked(
                requestedMode = requestedMode,
                originPolicy = ROUTE_ORIGIN_CURRENT_LOCATION,
                cachedOrigin = null,
                targetEndpoint = targetEndpoint,
                activeRouteSlot = slot
            )
        }
        return nativeRouteResponses(
            generation = generation,
            originLatitude = location.latitude,
            originLongitude = location.longitude,
            targetEndpoint = targetEndpoint,
            requestedMode = requestedMode,
            errorOffset = slot,
            activeRouteSlot = slot,
            originPolicy = ROUTE_ORIGIN_CURRENT_LOCATION,
            cachedOrigin = null
        )
    }

    private fun nativeActiveRouteReroute(
        requestedMode: Int,
        requestSlot: Int?
    ): List<Map<String, Any?>> {
        val snapshot = synchronized(this) {
            NativeActiveRouteSnapshot(
                originPolicy = nativeActiveRouteOriginPolicy,
                origin = nativeActiveRouteOrigin,
                target = nativeActiveRouteTarget,
                slot = nativeActiveRouteSlot
            )
        }
        val target = snapshot.target
            ?: return listOf(
                errorMessage(
                    category = ERROR_DESTINATION_NOT_CONFIGURED,
                    failedCommand = CMD_ROUTE_REQUEST,
                    text = "No active route target.",
                    offset = requestSlot ?: 0
                )
            )

        val originCoordinates = if (snapshot.originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            val origin = snapshot.origin
                ?: return listOf(
                    errorMessage(
                        category = ERROR_DESTINATION_NOT_CONFIGURED,
                        failedCommand = CMD_ROUTE_REQUEST,
                        text = "Active route origin is missing.",
                        offset = snapshot.slot ?: requestSlot ?: 0
                    )
                )
            origin.latitude to origin.longitude
        } else {
            val location = latestNativeLocation(ROUTE_LOCATION_FRESH_MILLIS)
                ?: return listOf(
                    errorMessage(
                        category = ERROR_LOCATION_UNAVAILABLE,
                        failedCommand = CMD_ROUTE_REQUEST,
                        text = "Waiting for GPS.",
                        offset = snapshot.slot ?: requestSlot ?: 0
                    )
                )
            location.latitude to location.longitude
        }
        val cachedOrigin = if (snapshot.originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            snapshot.origin
        } else {
            null
        }
        val generation = synchronized(this) {
            beginActiveRouteRequestLocked(
                requestedMode = requestedMode,
                originPolicy = snapshot.originPolicy,
                cachedOrigin = cachedOrigin,
                targetEndpoint = target,
                activeRouteSlot = snapshot.slot
            )
        }

        return nativeRouteResponses(
            generation = generation,
            originLatitude = originCoordinates.first,
            originLongitude = originCoordinates.second,
            targetEndpoint = target,
            requestedMode = requestedMode,
            errorOffset = snapshot.slot ?: requestSlot ?: 0,
            activeRouteSlot = snapshot.slot,
            originPolicy = snapshot.originPolicy,
            cachedOrigin = cachedOrigin
        )
    }

    private fun nativeRouteResponses(
        generation: Int,
        originLatitude: Double,
        originLongitude: Double,
        targetEndpoint: NativeRouteEndpoint,
        requestedMode: Int,
        errorOffset: Int,
        activeRouteSlot: Int?,
        originPolicy: String,
        cachedOrigin: NativeRouteEndpoint?
    ): List<Map<String, Any?>> {
        recordDiagnosticEntry(
            source = "route_worker",
            level = "info",
            eventName = "route_request_received",
            message = "Route provider request started.",
            commandId = CMD_ROUTE_REQUEST,
            savedLocationSlot = activeRouteSlot,
            routeOriginId = cachedOrigin?.placeId,
            routeTargetId = targetEndpoint.placeId,
            provider = "google_routes"
        )
        val route = mapTilesProvider.computeRoute(
            originLatitude = originLatitude,
            originLongitude = originLongitude,
            destinationAddress = targetEndpoint.address,
            destinationLatitude = targetEndpoint.latitude,
            destinationLongitude = targetEndpoint.longitude,
            travelMode = providerTravelMode(requestedMode),
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (!isCurrentRouteGeneration(generation)) {
            return emptyList()
        }

        if (route["ok"] != true) {
            val category = intValue(route, KEY_ERROR_CATEGORY) ?: ERROR_ROUTE_PROVIDER
            val detail = route["detail"] as? String ?: if (category == ERROR_NO_ROUTE) {
                "No route found."
            } else {
                "Route provider failed."
            }
            recordDiagnosticEntry(
                source = "route_worker",
                level = if (category == ERROR_NO_ROUTE) "warn" else "error",
                eventName = "route_provider_result",
                message = detail,
                commandId = CMD_ROUTE_REQUEST,
                errorCategory = if (category == 0) ERROR_ROUTE_PROVIDER else category,
                savedLocationSlot = activeRouteSlot,
                routeOriginId = cachedOrigin?.placeId,
                routeTargetId = targetEndpoint.placeId,
                provider = "google_routes",
                providerErrorClass = "route_error_$category",
                httpStatus = providerHttpStatus(route)
            )
            if (category == ERROR_NO_ROUTE) {
                clearActiveRouteIfCurrent(
                    generation,
                    routeErrorState(
                        category = ERROR_NO_ROUTE,
                        detail = detail,
                        requestedMode = requestedMode,
                        errorOffset = errorOffset
                    )
                )
                return listOf(
                    routePointsMessage(
                        emptyList(),
                        generation = generation,
                        routeMode = requestedMode
                    ),
                    errorMessage(
                        category = ERROR_NO_ROUTE,
                        failedCommand = CMD_ROUTE_REQUEST,
                        text = detail,
                        offset = errorOffset
                    )
                )
            }
            recordRouteErrorIfCurrent(
                generation,
                routeErrorState(
                    category = if (category == 0) ERROR_ROUTE_PROVIDER else category,
                    detail = detail,
                    requestedMode = requestedMode,
                    errorOffset = errorOffset
                )
            )
            return listOf(
                errorMessage(
                    category = if (category == 0) ERROR_ROUTE_PROVIDER else category,
                    failedCommand = CMD_ROUTE_REQUEST,
                    text = detail,
                    offset = errorOffset
                )
            )
        }

        val routePoints = listOfMaps(route["routePoints"])
        val fullRoutePoints = listOfMaps(route["fullRoutePoints"]).ifEmpty { routePoints }
        if (routePoints.size < 2) {
            recordDiagnosticEntry(
                source = "route_worker",
                level = "error",
                eventName = "route_provider_result",
                message = "Route geometry is invalid.",
                commandId = CMD_ROUTE_REQUEST,
                errorCategory = ERROR_ROUTE_PROVIDER,
                savedLocationSlot = activeRouteSlot,
                routeOriginId = cachedOrigin?.placeId,
                routeTargetId = targetEndpoint.placeId,
                provider = "google_routes",
                providerErrorClass = "invalid_geometry"
            )
            recordRouteErrorIfCurrent(
                generation,
                routeErrorState(
                    category = ERROR_ROUTE_PROVIDER,
                    detail = "Route geometry is invalid.",
                    requestedMode = requestedMode,
                    errorOffset = errorOffset
                )
            )
            return listOf(
                errorMessage(
                    category = ERROR_ROUTE_PROVIDER,
                    failedCommand = CMD_ROUTE_REQUEST,
                    text = "Route geometry is invalid.",
                    offset = errorOffset
                )
            )
        }

        val routeSteps = listOfMaps(route["steps"])
        val accepted = synchronized(this) {
            if (generation == nativeRouteGeneration) {
                nativeRoutePoints = routePoints
                nativeFullRoutePoints = fullRoutePoints
                nativeRouteSteps = routeSteps
                nativeActiveRouteOriginPolicy = originPolicy
                nativeActiveRouteOrigin =
                    if (originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE) cachedOrigin else null
                nativeActiveRouteTarget = targetEndpoint
                nativeActiveRouteSlot = activeRouteSlot
                nativeActiveRouteSummary = routeSummary(route, requestedMode)
                nativeActiveRouteMode = requestedMode
                nativeLastRouteRequestedAtMillis = System.currentTimeMillis()
                nativeLastRouteError = null
                true
            } else {
                false
            }
        }
        if (!accepted) {
            return emptyList()
        }
        recordDiagnosticEntry(
            source = "route_worker",
            level = "info",
            eventName = "route_provider_result",
            message = "Route provider returned a route.",
            commandId = CMD_ROUTE_REQUEST,
            savedLocationSlot = activeRouteSlot,
            routeOriginId = cachedOrigin?.placeId,
            routeTargetId = targetEndpoint.placeId,
            provider = "google_routes"
        )
        val responses = mutableListOf(
            routePointsMessage(
                routePoints,
                generation = generation,
                routeMode = requestedMode
            )
        )
        if (routeSteps.isNotEmpty()) {
            navStepsMessageFromSteps(routeSteps, 0)?.let { responses.add(it) }
        }
        return responses
    }

    private fun startNativeNavigation(request: Map<*, *>): List<Map<String, Any?>> {
        val requestedMode = travelProtocolValue(intValue(request, "travelMode") ?: nativeTravelMode)
        val destinationMap = request["destination"] as? Map<*, *>
            ?: return listOf(
                errorMessage(
                    category = ERROR_DESTINATION_NOT_CONFIGURED,
                    failedCommand = CMD_ROUTE_REQUEST,
                    text = "Destination is missing."
                )
            )
        val destination = parseNativeRouteEndpoint(destinationMap)
            ?: return listOf(
                errorMessage(
                    category = ERROR_DESTINATION_NOT_CONFIGURED,
                    failedCommand = CMD_ROUTE_REQUEST,
                    text = "Destination coordinates are invalid."
                )
            )

        val originPolicy = if (stringValue(request, "originPolicy") == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            ROUTE_ORIGIN_EXPLICIT_PLACE
        } else {
            ROUTE_ORIGIN_CURRENT_LOCATION
        }
        val cachedOrigin: NativeRouteEndpoint?
        val originCoordinates = if (originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            val originMap = request["origin"] as? Map<*, *>
                ?: return listOf(
                    errorMessage(
                        category = ERROR_DESTINATION_NOT_CONFIGURED,
                        failedCommand = CMD_ROUTE_REQUEST,
                        text = "Route origin is missing."
                    )
                )
            val origin = parseNativeRouteEndpoint(originMap)
                ?: return listOf(
                    errorMessage(
                        category = ERROR_DESTINATION_NOT_CONFIGURED,
                        failedCommand = CMD_ROUTE_REQUEST,
                        text = "Origin coordinates are invalid."
                    )
                )
            cachedOrigin = origin
            origin.latitude to origin.longitude
        } else {
            val location = latestNativeLocation(ROUTE_LOCATION_FRESH_MILLIS)
                ?: return listOf(
                    errorMessage(
                        category = ERROR_LOCATION_UNAVAILABLE,
                        failedCommand = CMD_ROUTE_REQUEST,
                        text = "Waiting for GPS."
                    )
                )
            cachedOrigin = null
            location.latitude to location.longitude
        }

        val generation = synchronized(this) {
            beginActiveRouteRequestLocked(
                requestedMode = requestedMode,
                originPolicy = originPolicy,
                cachedOrigin = cachedOrigin,
                targetEndpoint = destination,
                activeRouteSlot = null
            )
        }
        return nativeRouteResponses(
            generation = generation,
            originLatitude = originCoordinates.first,
            originLongitude = originCoordinates.second,
            targetEndpoint = destination,
            requestedMode = requestedMode,
            errorOffset = 0,
            activeRouteSlot = null,
            originPolicy = originPolicy,
            cachedOrigin = cachedOrigin
        )
    }

    private fun nativeRouteWindowRequest(message: Map<*, *>): List<Map<String, Any?>> {
        val centerX = intValue(message, KEY_WORLD_X)
        val centerY = intValue(message, KEY_WORLD_Y)
        val zoom = intValue(message, KEY_TILE_ZOOM)
        val width = intValue(message, KEY_WIDTH)
        val height = intValue(message, KEY_HEIGHT)
        if (centerX == null || centerY == null || zoom == null || width == null || height == null) {
            return listOf(
                errorMessage(
                    category = ERROR_ROUTE_PROVIDER,
                    failedCommand = CMD_ROUTE_WINDOW_REQUEST,
                    text = "Route window request missing bounds."
                )
            )
        }

        val requestedGeneration = intValue(message, KEY_TOTAL_BYTES)
        val snapshot = synchronized(this) {
            NativeRouteWindowSnapshot(
                generation = nativeRouteGeneration,
                fullRoutePoints = nativeFullRoutePoints
            )
        }
        val responseGeneration = requestedGeneration ?: snapshot.generation
        if (
            snapshot.fullRoutePoints.size < 2 ||
            (requestedGeneration != null && requestedGeneration != snapshot.generation)
        ) {
            return listOf(
                routeWindowPointsMessage(
                    points = emptyList(),
                    generation = responseGeneration,
                    centerX = centerX,
                    centerY = centerY,
                    zoom = zoom,
                    width = width,
                    height = height
                )
            )
        }

        val points = routeWindowPoints(snapshot.fullRoutePoints, centerX, centerY, width, height)
        return listOf(
            routeWindowPointsMessage(
                points = points,
                generation = snapshot.generation,
                centerX = centerX,
                centerY = centerY,
                zoom = zoom,
                width = width,
                height = height
            )
        )
    }

    private fun nativeNavSteps(message: Map<*, *>): List<Map<String, Any?>> {
        val firstIndex = (intValue(message, KEY_BUTTON_ID) ?: 0).coerceIn(0, 255)
        if (nativeRouteSteps.isEmpty()) {
            return listOf(
                errorMessage(
                    category = ERROR_ROUTE_PROVIDER,
                    failedCommand = CMD_NAV_STEPS,
                    text = "No nav-step cache.",
                    offset = firstIndex
                )
            )
        }
        val response = navStepsMessage(firstIndex)
        if (response != null) {
            return listOf(response)
        }
        return listOf(
            errorMessage(
                category = ERROR_ROUTE_PROVIDER,
                failedCommand = CMD_NAV_STEPS,
                text = "Requested nav-step chunk is empty.",
                offset = firstIndex
            )
        )
    }

    private fun isCurrentRouteGeneration(generation: Int): Boolean =
        synchronized(this) { generation == nativeRouteGeneration }

    private fun beginActiveRouteRequestLocked(
        requestedMode: Int,
        originPolicy: String,
        cachedOrigin: NativeRouteEndpoint?,
        targetEndpoint: NativeRouteEndpoint,
        activeRouteSlot: Int?
    ): Int {
        nativeTravelMode = requestedMode
        nativeRouteGeneration += 1
        nativeActiveRouteOriginPolicy = originPolicy
        nativeActiveRouteOrigin = if (originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE) {
            cachedOrigin
        } else {
            null
        }
        nativeActiveRouteTarget = targetEndpoint
        nativeActiveRouteSlot = activeRouteSlot
        nativeActiveRouteSummary = null
        nativeLastRouteRequestedAtMillis = System.currentTimeMillis()
        nativeLastRouteError = null
        return nativeRouteGeneration
    }

    private fun activeRouteMessages(): List<Map<String, Any?>> {
        val snapshot = synchronized(this) {
            NativeActiveRouteMessagesSnapshot(
                generation = nativeRouteGeneration,
                routePoints = nativeRoutePoints,
                routeSteps = nativeRouteSteps,
                routeMode = nativeActiveRouteMode ?: nativeTravelMode
            )
        }
        val routePoints = snapshot.routePoints
        if (routePoints.size < 2) {
            return emptyList()
        }
        val responses = mutableListOf(
            routePointsMessage(
                routePoints,
                generation = snapshot.generation,
                routeMode = snapshot.routeMode
            )
        )
        if (snapshot.routeSteps.isNotEmpty()) {
            navStepsMessageFromSteps(snapshot.routeSteps, 0)?.let { responses.add(it) }
        }
        return responses
    }

    private fun clearActiveRouteIfCurrent(
        generation: Int,
        lastError: Map<String, Any?>? = null
    ) {
        synchronized(this) {
            if (generation == nativeRouteGeneration) {
                clearActiveRouteLocked()
                nativeLastRouteError = lastError
            }
        }
    }

    private fun recordRouteErrorIfCurrent(generation: Int, lastError: Map<String, Any?>) {
        synchronized(this) {
            if (generation == nativeRouteGeneration) {
                nativeLastRouteError = lastError
            }
        }
    }

    private fun clearActiveRouteLocked() {
        nativeRoutePoints = emptyList()
        nativeFullRoutePoints = emptyList()
        nativeRouteSteps = emptyList()
        nativeActiveRouteOriginPolicy = ROUTE_ORIGIN_CURRENT_LOCATION
        nativeActiveRouteOrigin = null
        nativeActiveRouteTarget = null
        nativeActiveRouteSlot = null
        nativeActiveRouteSummary = null
        nativeActiveRouteMode = null
        nativeLastRouteRequestedAtMillis = 0L
        nativeLastRouteError = null
    }

    private fun nativeRouteEndpoint(destination: NativeDestination): NativeRouteEndpoint =
        NativeRouteEndpoint(
            label = destination.label,
            address = destination.address,
            latitude = destination.latitude,
            longitude = destination.longitude,
            placeId = destination.placeId
        )

    private fun routeErrorState(
        category: Int,
        detail: String,
        requestedMode: Int,
        errorOffset: Int
    ): Map<String, Any?> =
        mapOf(
            "category" to category,
            "detail" to detail,
            "travelMode" to requestedMode,
            "offset" to errorOffset,
            "timestampMillis" to System.currentTimeMillis()
        )

    private fun routeSummary(route: Map<*, *>, requestedMode: Int): Map<String, Any?> =
        mapOf(
            "distanceMeters" to intValue(route, "distanceMeters"),
            "durationSeconds" to intValue(route, "durationSeconds"),
            "encodedPolyline" to stringValue(route, "encodedPolyline").takeIf { it.isNotBlank() },
            "routeWarning" to stringValue(route, "routeWarning").takeIf { it.isNotBlank() },
            "travelMode" to requestedMode,
            "timestampMillis" to System.currentTimeMillis()
        )

    private fun destinationsMessage(): Map<String, Any?> {
        val destinations = synchronized(this) { nativeDestinations.toList() }
        val payload = encodeDestinations(destinations)
        return watchMessage(
            CMD_DESTINATIONS,
            mapOf(
                KEY_TOTAL_BYTES to payload.size,
                KEY_CHUNK_DATA to payload
            )
        )
    }

    private fun setNativeDestination(destination: Map<*, *>): List<Map<String, Any?>> {
        val update = parseNativeDestinationPayload(destination) { category, failedCommand, text, offset ->
            errorMessage(
                category = category,
                failedCommand = failedCommand,
                text = text,
                offset = offset
            )
        }
        if (update.error != null) {
            return listOf(update.error)
        }
        synchronized(this) {
            val destinationRecord = update.destination
            if (destinationRecord == null) {
                nativeDestinations.removeAll { it.slot == update.slot }
            } else {
                val existing = nativeDestinations.indexOfFirst { it.slot == destinationRecord.slot }
                if (existing >= 0) {
                    nativeDestinations[existing] = destinationRecord
                } else {
                    if (nativeDestinations.size >= MAX_DESTINATION_RECORDS) {
                        return listOf(
                            errorMessage(
                                category = ERROR_DESTINATION_NOT_CONFIGURED,
                                failedCommand = CMD_DESTINATIONS,
                                text = "Destination count exceeds protocol limit."
                            )
                        )
                    }
                    nativeDestinations.add(destinationRecord)
                }
            }
            nativeDestinations.sortBy { it.slot }
            nativeRouteGeneration += 1
            if (nativeActiveRouteSlot == update.slot) {
                clearActiveRouteLocked()
            }
            persistNativeDestinations(this, nativeDestinations)
        }
        return listOf(destinationsMessage())
    }

    private fun setNativeDestinations(destinations: List<*>): List<Map<String, Any?>> {
        if (destinations.size > MAX_DESTINATION_RECORDS) {
            return listOf(
                errorMessage(
                    category = ERROR_DESTINATION_NOT_CONFIGURED,
                    failedCommand = CMD_DESTINATIONS,
                    text = "Destination count exceeds protocol limit."
                )
            )
        }
        val nextDestinations = mutableListOf<NativeDestination>()
        val seenSlots = mutableSetOf<Int>()
        for (destination in destinations) {
            val destinationMap = destination as? Map<*, *>
                ?: return listOf(
                    errorMessage(
                        category = ERROR_DESTINATION_NOT_CONFIGURED,
                        failedCommand = CMD_DESTINATIONS,
                        text = "Destination record is invalid."
                    )
                )
            val update = parseNativeDestinationPayload(destinationMap) { category, failedCommand, text, offset ->
                errorMessage(
                    category = category,
                    failedCommand = failedCommand,
                    text = text,
                    offset = offset
                )
            }
            if (update.error != null) {
                return listOf(update.error)
            }
            if (!seenSlots.add(update.slot)) {
                return listOf(
                    errorMessage(
                        category = ERROR_DESTINATION_NOT_CONFIGURED,
                        failedCommand = CMD_DESTINATIONS,
                        text = "Destination slot appears more than once.",
                        offset = update.slot
                    )
                )
            }
            update.destination?.let { nextDestinations.add(it) }
        }
        synchronized(this) {
            nativeDestinations.clear()
            nativeDestinations.addAll(nextDestinations.sortedBy { it.slot })
            nativeRouteGeneration += 1
            if (nativeActiveRouteSlot != null) {
                clearActiveRouteLocked()
            }
            persistNativeDestinations(this, nativeDestinations)
        }
        return listOf(destinationsMessage())
    }

    private fun exportNativeDestinations(): List<Map<String, Any?>> =
        synchronized(this) {
            nativeDestinations
                .sortedBy { it.slot }
                .map { nativeDestinationMap(it) }
        }

    private fun loadNativeDestinations() {
        val loaded = readPersistedNativeDestinations(this)
        synchronized(this) {
            nativeDestinations.clear()
            nativeDestinations.addAll(loaded.orEmpty())
            nativeDestinations.sortBy { it.slot }
        }
    }

    private fun setNativeSettings(settings: Map<*, *>): List<Map<String, Any?>> {
        val messages = mutableListOf<Map<String, Any?>>()
        var changed = false
        var themeChanged = false

        intValue(settings, THEME_MODE_SETTING)?.let { value ->
            val next = themeProtocolValue(value)
            if (nativeThemeMode != next) {
                themeChanged = true
            }
            nativeThemeMode = next
            messages.add(themeMessage())
            changed = true
        }
        intValue(settings, TRAVEL_MODE_SETTING)?.let { value ->
            nativeTravelMode = travelProtocolValue(value)
            messages.add(travelModeMessage())
            changed = true
        }
        intValue(settings, UNITS_MODE_SETTING)?.let { value ->
            nativeUnitsMode = unitsProtocolValue(value)
            messages.add(unitsMessage())
            changed = true
        }
        intValue(settings, BACKLIGHT_MODE_SETTING)?.let { value ->
            nativeBacklightMode = backlightProtocolValue(value)
            messages.add(backlightMessage())
            changed = true
        }
        intValue(settings, MAP_ORIENTATION_SETTING)?.let { value ->
            val previous = nativeMapOrientation
            nativeMapOrientation = mapOrientationProtocolValue(value)
            messages.add(mapOrientationMessage())
            changed = true
            if (previous != nativeMapOrientation) {
                recordMapOrientationChanged("flutter", nativeMapOrientation)
            }
        }
        intValue(settings, TILE_ANIMATION_MODE_SETTING)?.let { value ->
            nativeTileAnimationMode = tileAnimationProtocolValue(value)
            messages.add(tileAnimationMessage())
            changed = true
        }

        if (changed) {
            saveDisplaySettings()
        }
        if (themeChanged) {
            mapTilesProvider.clearProviderSessions()
            messages.add(mapSettingsMessage(reason = 4))
        }
        return messages
    }

    private fun displaySettingsMap(): Map<String, Any?> =
        synchronized(this) {
            displaySettingsMap(
                NativeDisplaySettings(
                    themeMode = nativeThemeMode,
                    travelMode = nativeTravelMode,
                    unitsMode = nativeUnitsMode,
                    backlightMode = nativeBacklightMode,
                    mapOrientation = nativeMapOrientation,
                    tileAnimationMode = nativeTileAnimationMode
                )
            )
        }

    private fun loadDisplaySettings() {
        val settings = loadNativeDisplaySettings(this)
        nativeThemeMode = settings.themeMode
        nativeTravelMode = settings.travelMode
        nativeUnitsMode = settings.unitsMode
        nativeBacklightMode = settings.backlightMode
        nativeMapOrientation = settings.mapOrientation
        nativeTileAnimationMode = settings.tileAnimationMode
    }

    private fun saveDisplaySettings() {
        saveNativeDisplaySettings(
            this,
            NativeDisplaySettings(
                themeMode = nativeThemeMode,
                travelMode = nativeTravelMode,
                unitsMode = nativeUnitsMode,
                backlightMode = nativeBacklightMode,
                mapOrientation = nativeMapOrientation,
                tileAnimationMode = nativeTileAnimationMode
            )
        )
    }

    private fun routePointsMessage(
        points: List<Map<*, *>>,
        generation: Int = synchronized(this) { nativeRouteGeneration },
        routeMode: Int = synchronized(this) { nativeActiveRouteMode ?: nativeTravelMode }
    ): Map<String, Any?> {
        recordDiagnosticEntry(
            source = "route_worker",
            level = "info",
            eventName = "route_points_sent",
            message = "Route points sent.",
            commandId = CMD_ROUTE_POINTS
        )
        return watchMessage(
            CMD_ROUTE_POINTS,
            mapOf(
                KEY_BUTTON_ID to 1,
                KEY_IS_COLOR to travelProtocolValue(routeMode),
                KEY_TOTAL_BYTES to generation,
                KEY_CHUNK_DATA to encodeRoutePoints(points)
            )
        )
    }

    private fun routeWindowPointsMessage(
        points: List<Map<*, *>>,
        generation: Int,
        centerX: Int,
        centerY: Int,
        zoom: Int,
        width: Int,
        height: Int
    ): Map<String, Any?> {
        recordDiagnosticEntry(
            source = "route_worker",
            level = "info",
            eventName = "route_window_points_sent",
            message = "Route detail window sent.",
            commandId = CMD_ROUTE_WINDOW_POINTS,
            tileX = centerX,
            tileY = centerY,
            tileZoom = zoom
        )
        return watchMessage(
            CMD_ROUTE_WINDOW_POINTS,
            mapOf(
                KEY_WORLD_X to centerX,
                KEY_WORLD_Y to centerY,
                KEY_TILE_ZOOM to zoom,
                KEY_WIDTH to width.coerceAtLeast(1),
                KEY_HEIGHT to height.coerceAtLeast(1),
                KEY_TOTAL_BYTES to generation,
                KEY_CHUNK_DATA to encodeRoutePoints(points)
            )
        )
    }

    private fun navStepsMessage(firstIndex: Int): Map<String, Any?>? {
        val steps = synchronized(this) { nativeRouteSteps }
        return navStepsMessageFromSteps(steps, firstIndex)
    }

    private fun navStepsMessageFromSteps(
        steps: List<Map<*, *>>,
        firstIndex: Int
    ): Map<String, Any?>? {
        val payload = encodeNavSteps(steps, firstIndex) ?: return null
        recordDiagnosticEntry(
            source = "route_worker",
            level = "info",
            eventName = "nav_steps_sent",
            message = "Navigation step chunk sent.",
            commandId = CMD_NAV_STEPS
        )
        return watchMessage(
            CMD_NAV_STEPS,
            mapOf(KEY_CHUNK_DATA to payload)
        )
    }

    private fun mapSettingsMessage(reason: Int): Map<String, Any?> =
        mapTilesProvider.currentMapTileSettings().let { settings ->
            watchMessage(
                CMD_MAP_SETTINGS,
                mapOf(
                    KEY_BUTTON_ID to reason,
                    KEY_WIDTH to settings.watchTileWidth,
                    KEY_HEIGHT to settings.watchTileHeight,
                    KEY_TOTAL_BYTES to synchronized(this) {
                        nativeMapSettingsGeneration += 1
                        nativeMapSettingsGeneration
                    }
                )
            )
        }

    private fun themeMessage(): Map<String, Any?> =
        watchMessage(CMD_THEME, mapOf(KEY_BUTTON_ID to synchronized(this) { nativeThemeMode }))

    private fun travelModeMessage(): Map<String, Any?> =
        watchMessage(CMD_TRAVEL_MODE, mapOf(KEY_BUTTON_ID to synchronized(this) { nativeTravelMode }))

    private fun unitsMessage(): Map<String, Any?> =
        watchMessage(CMD_UNITS, mapOf(KEY_BUTTON_ID to synchronized(this) { nativeUnitsMode }))

    private fun backlightMessage(): Map<String, Any?> =
        watchMessage(CMD_BACKLIGHT, mapOf(KEY_BUTTON_ID to synchronized(this) { nativeBacklightMode }))

    private fun mapOrientationMessage(): Map<String, Any?> =
        watchMessage(
            CMD_MAP_ORIENTATION,
            mapOf(
                KEY_BUTTON_ID to synchronized(this) { nativeMapOrientation },
                KEY_TOTAL_BYTES to synchronized(this) {
                    nativeDisplaySettingsGeneration += 1
                    nativeDisplaySettingsGeneration
                }
            )
        )

    private fun tileAnimationMessage(): Map<String, Any?> =
        watchMessage(CMD_TILE_ANIMATION, mapOf(KEY_BUTTON_ID to synchronized(this) { nativeTileAnimationMode }))

    private fun errorMessage(
        category: Int,
        failedCommand: Int,
        text: String,
        offset: Int = 0,
        worldX: Int? = null,
        worldY: Int? = null,
        zoom: Int? = null,
        retryImmediately: Boolean = false
    ): Map<String, Any?> {
        val safeText = redactDiagnosticMessage(text)
        synchronized(this) {
            lastSafeErrorCategory = category
            lastSafeErrorText = safeText
        }
        recordDiagnosticEntry(
            source = "android_bridge",
            level = diagnosticLevel(category),
            eventName = "error_state_sent",
            message = safeText,
            commandId = failedCommand.takeIf { it > 0 },
            errorCategory = category,
            tileX = worldX,
            tileY = worldY,
            tileZoom = zoom,
            savedLocationSlot = offset.takeIf {
                failedCommand == CMD_ROUTE_REQUEST || failedCommand == CMD_DESTINATIONS
            }
        )
        val fields = mutableMapOf<String, Any?>(
            KEY_BUTTON_ID to category,
            KEY_CHUNK_INDEX to failedCommand,
            KEY_CHUNK_OFFSET to offset,
            KEY_INSTRUCTION to truncatedUtf8Text(safeText, MAX_WATCH_TEXT_BYTES)
        )
        if (worldX != null) {
            fields[KEY_WORLD_X] = worldX
        }
        if (worldY != null) {
            fields[KEY_WORLD_Y] = worldY
        }
        if (zoom != null) {
            fields[KEY_TILE_ZOOM] = zoom
        }
        if (retryImmediately) {
            fields[KEY_TOTAL_BYTES] = 1
        }
        return watchMessage(CMD_ERROR_STATE, fields)
    }

    private fun latestNativeLocation(
        maxAgeMillis: Long = LOCATION_STALE_FOR_UI_MILLIS,
        requestIfStale: Boolean = true
    ): Location? {
        if (!requestIfStale) {
            return WatchLocationStreamer.latestLocation(maxAgeMillis)
        }
        return WatchLocationStreamer.awaitCurrentLocation(
            applicationContext,
            maxAgeMillis,
            LOCATION_REQUEST_TIMEOUT_MILLIS
        )
    }

    private fun seedDevelopmentApiKeyIfPresent() {
        val developmentKey = BuildConfig.MAPPY_DEV_GOOGLE_API_KEY.trim()
        if (developmentKey.isEmpty()) {
            return
        }

        val currentKey = try {
            apiKeyStore.getPlaintextKey()
        } catch (_: Exception) {
            null
        }

        val isSeededDevelopmentKey = apiKeyStore.hasSeededDevelopmentKeyMarker()
        if (currentKey == null || (isSeededDevelopmentKey && currentKey != developmentKey)) {
            mapTilesProvider.clearProviderSessions()
            apiKeyStore.storeSeededDevelopmentApiKey(developmentKey)
        }
    }

    private fun isSeededDevelopmentApiKey(): Boolean {
        val developmentKey = BuildConfig.MAPPY_DEV_GOOGLE_API_KEY.trim()
        if (developmentKey.isEmpty()) {
            return false
        }
        return try {
            apiKeyStore.isSeededDevelopmentApiKey(developmentKey)
        } catch (_: Exception) {
            false
        }
    }

}
