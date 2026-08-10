package com.leapwardkoex.mappy

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import com.google.android.gms.location.CurrentLocationRequest
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

internal object WatchLocationStreamer {
    private val lock = Any()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var fusedClient: FusedLocationProviderClient? = null
    private var bridge: WatchAppMessageBridge? = null
    private var onStatusChanged: (() -> Unit)? = null
    private var onLocationAccepted: ((Location) -> Unit)? = null
    private var onStreamError: ((String) -> Unit)? = null
    private var requested = false
    private var callback: LocationCallback? = null
    private var latestLocation: Location? = null
    private var latestAcceptedGpsCandidate: GpsFixCandidate? = null
    private var lastGpsSentWorldX: Int? = null
    private var lastGpsSentWorldY: Int? = null
    private var lastGpsSentHeading: Int? = null
    private var lastGpsSentAtMillis = 0L
    private var lastGpsSequence = initialGpsSequence()
    private var lastGpsStreamErrorText: String? = null
    private var lastGpsStreamErrorAtMillis = 0L
    private val resendRunnable = Runnable { handleResendTick() }

    fun attach(
        context: Context,
        bridge: WatchAppMessageBridge?,
        onStatusChanged: (() -> Unit)? = null,
        onLocationAccepted: ((Location) -> Unit)? = null,
        onStreamError: ((String) -> Unit)? = null
    ) {
        val applicationContext = context.applicationContext
        synchronized(lock) {
            appContext = applicationContext
            fusedClient = fusedClient ?: LocationServices.getFusedLocationProviderClient(applicationContext)
            this.bridge = bridge
            this.onStatusChanged = onStatusChanged
            this.onLocationAccepted = onLocationAccepted
            this.onStreamError = onStreamError
        }
        if (isRequested()) {
            startIfPossible(applicationContext)
        } else {
            notifyStatusChanged()
        }
    }

    fun detachBridge(bridge: WatchAppMessageBridge?) {
        synchronized(lock) {
            if (this.bridge === bridge) {
                this.bridge = null
                onStatusChanged = null
                onLocationAccepted = null
                onStreamError = null
            }
        }
    }

    fun request(context: Context) {
        synchronized(lock) {
            requested = true
        }
        startIfPossible(context.applicationContext)
    }

    fun stop(context: Context? = null, sendError: Boolean = false, text: String = "Live watch GPS stopped.") {
        val callbackToRemove: LocationCallback?
        val client: FusedLocationProviderClient?
        synchronized(lock) {
            requested = false
            callbackToRemove = callback
            callback = null
            lastGpsSentWorldX = null
            lastGpsSentWorldY = null
            lastGpsSentHeading = null
            lastGpsSentAtMillis = 0L
        }
        mainHandler.removeCallbacks(resendRunnable)
        client = synchronized(lock) {
            fusedClient ?: context?.applicationContext?.let {
                LocationServices.getFusedLocationProviderClient(it)
            }
        }
        if (callbackToRemove != null && client != null) {
            client.removeLocationUpdates(callbackToRemove)
        }
        if (sendError) {
            enqueueStreamError(text)
        }
        notifyStatusChanged()
    }

    fun isRequested(): Boolean =
        synchronized(lock) {
            requested
        }

    fun isStreaming(): Boolean =
        synchronized(lock) {
            callback != null
        }

    fun status(context: Context, permissionState: String): Map<String, Any?> {
        val latest = synchronized(lock) { latestLocation?.let { Location(it) } }
        val ageMillis = latest?.let { System.currentTimeMillis() - it.time }
        return mapOf(
            "requested" to isRequested(),
            "streaming" to isStreaming(),
            "providers" to listOf("fused"),
            "updateSource" to "fused",
            "permissionState" to permissionState,
            "backgroundLocationGranted" to hasBackgroundLocation(context),
            "backgroundLocationRequired" to backgroundLocationPermissionApplies(),
            "headingAvailable" to (latest?.hasBearing() == true),
            "lastFixAgeMillis" to ageMillis?.coerceAtLeast(0L),
            "lastFixFresh" to (latest != null && isFresh(latest, LOCATION_STALE_FOR_UI_MILLIS)),
            "requestedMinIntervalMillis" to GPS_STREAM_MIN_INTERVAL_MILLIS,
            "requestedMinDistanceMeters" to GPS_STREAM_MIN_DISTANCE_METERS.toDouble(),
            "maxResendIntervalMillis" to GPS_STREAM_MAX_INTERVAL_MILLIS
        )
    }

    fun latestLocation(maxAgeMillis: Long): Location? =
        synchronized(lock) { latestLocation?.let { Location(it) } }
            ?.takeIf { isFresh(it, maxAgeMillis) }

    fun awaitCurrentLocation(context: Context, maxAgeMillis: Long, timeoutMillis: Long): Location? {
        latestLocation(maxAgeMillis)?.let { return it }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            currentLocation(context, timeoutMillis) {}
            return null
        }
        if (!hasAnyLocationPermission(context) || !hasEnabledLocationProvider(context)) {
            return null
        }

        val latch = CountDownLatch(1)
        var resolved: Location? = null
        currentLocation(context, timeoutMillis) { location ->
            resolved = location
            latch.countDown()
        }
        latch.await(timeoutMillis.coerceAtLeast(0L), TimeUnit.MILLISECONDS)
        return resolved?.takeIf { isFresh(it, maxAgeMillis) }
    }

    fun currentLocation(context: Context, timeoutMillis: Long, onResult: (Location?) -> Unit) {
        val applicationContext = context.applicationContext
        if (!hasAnyLocationPermission(applicationContext) || !hasEnabledLocationProvider(applicationContext)) {
            onResult(null)
            return
        }

        latestLocation(LOCATION_FRESH_MILLIS)?.let {
            onResult(it)
            return
        }

        val client = LocationServices.getFusedLocationProviderClient(applicationContext)
        try {
            client.lastLocation
                .addOnSuccessListener { lastKnown ->
                    if (lastKnown != null && isFresh(lastKnown, LOCATION_FRESH_MILLIS)) {
                        handleLocation(lastKnown, force = true)
                        onResult(Location(lastKnown))
                    } else {
                        requestCurrentLocation(client, timeoutMillis, onResult)
                    }
                }
                .addOnFailureListener {
                    requestCurrentLocation(client, timeoutMillis, onResult)
                }
        } catch (_: SecurityException) {
            onResult(null)
        }
    }

    fun openAppLocationSettings(context: Context) {
        val intent = Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.fromParts("package", context.packageName, null)
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        context.startActivity(intent)
    }

    fun permissionState(context: Context, wasForegroundRequested: Boolean): String {
        val locationEnabled = hasEnabledLocationProvider(context)
        val fine = hasFineLocation(context)
        val coarse = hasCoarseLocation(context)
        val background = hasBackgroundLocation(context)

        if (fine) {
            return when {
                !locationEnabled -> "serviceDisabled"
                background -> "grantedAlwaysPrecise"
                else -> "grantedPrecise"
            }
        }
        if (coarse) {
            return when {
                !locationEnabled -> "serviceDisabled"
                background -> "grantedAlwaysApproximate"
                else -> "grantedApproximate"
            }
        }
        if (!wasForegroundRequested) {
            return "requestAvailable"
        }
        return if (
            context is android.app.Activity &&
            !context.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_FINE_LOCATION) &&
            !context.shouldShowRequestPermissionRationale(Manifest.permission.ACCESS_COARSE_LOCATION)
        ) {
            "permanentlyDenied"
        } else {
            "denied"
        }
    }

    fun hasFineLocation(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun hasCoarseLocation(context: Context): Boolean =
        context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    fun hasAnyLocationPermission(context: Context): Boolean =
        hasFineLocation(context) || hasCoarseLocation(context)

    fun hasBackgroundLocation(context: Context): Boolean =
        !backgroundLocationPermissionApplies() ||
            context.checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    fun backgroundLocationPermissionApplies(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    fun hasEnabledLocationProvider(context: Context): Boolean {
        val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as LocationManager
        return listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .any { provider ->
                try {
                    locationManager.isProviderEnabled(provider)
                } catch (_: Exception) {
                    false
                }
            }
    }

    private fun startIfPossible(context: Context) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { startIfPossible(context.applicationContext) }
            return
        }
        if (!isRequested()) {
            return
        }
        if (isStreaming()) {
            notifyStatusChanged()
            return
        }
        if (!hasAnyLocationPermission(context)) {
            enqueueStreamError("Location permission is required for live watch GPS.")
            notifyStatusChanged()
            return
        }
        if (!hasBackgroundLocation(context)) {
            enqueueStreamError("All-the-time location is required for live watch GPS.")
            notifyStatusChanged()
            return
        }
        if (!hasEnabledLocationProvider(context)) {
            enqueueStreamError("Location services are disabled.")
            notifyStatusChanged()
            return
        }

        val client = synchronized(lock) {
            appContext = context.applicationContext
            fusedClient = fusedClient ?: LocationServices.getFusedLocationProviderClient(context.applicationContext)
            fusedClient
        } ?: return
        val nextCallback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.locations.forEach { location ->
                    handleLocation(location, force = false)
                }
            }
        }
        synchronized(lock) {
            callback = nextCallback
        }
        try {
            client.requestLocationUpdates(fusedRequest(), nextCallback, Looper.getMainLooper())
            client.lastLocation.addOnSuccessListener { lastKnown ->
                if (lastKnown != null && isFresh(lastKnown, LOCATION_STALE_FOR_UI_MILLIS)) {
                    handleLocation(lastKnown, force = false)
                }
            }
        } catch (_: SecurityException) {
            synchronized(lock) {
                if (callback === nextCallback) {
                    callback = null
                }
            }
            enqueueStreamError("Location permission is required for live watch GPS.")
        }
        scheduleResend()
        notifyStatusChanged()
    }

    private fun requestCurrentLocation(
        client: FusedLocationProviderClient,
        timeoutMillis: Long,
        onResult: (Location?) -> Unit
    ) {
        val timeout = timeoutMillis.coerceIn(0L, LOCATION_REQUEST_TIMEOUT_MILLIS)
        val cancellation = CancellationTokenSource()
        var finished = false
        fun finish(location: Location?) {
            if (finished) {
                return
            }
            finished = true
            cancellation.cancel()
            location?.let { handleLocation(it, force = true) }
            onResult(location?.let { Location(it) })
        }

        mainHandler.postDelayed({ finish(null) }, timeout)
        try {
            client.getCurrentLocation(currentLocationRequest(), cancellation.token)
                .addOnSuccessListener { finish(it) }
                .addOnFailureListener { finish(null) }
        } catch (_: SecurityException) {
            finish(null)
        }
    }

    private fun handleLocation(location: Location, force: Boolean) {
        val candidate = gpsFixCandidate(location)
        val nowMillis = System.currentTimeMillis()
        val accepted = synchronized(lock) {
            if (GpsFixFilter.shouldAccept(
                    candidate,
                    latestAcceptedGpsCandidate,
                    nowMillis,
                    LOCATION_STALE_FOR_UI_MILLIS
                )
            ) {
                latestAcceptedGpsCandidate = candidate
                latestLocation = Location(location)
                true
            } else {
                false
            }
        }
        if (!accepted) {
            notifyStatusChanged()
            scheduleResend()
            return
        }

        if (sendGpsUpdate(location, force)) {
            synchronized(lock) {
                lastGpsStreamErrorText = null
                lastGpsStreamErrorAtMillis = 0L
            }
            synchronized(lock) { onLocationAccepted }?.invoke(location)
            notifyStatusChanged()
        }
        scheduleResend()
    }

    private fun handleResendTick() {
        if (!isRequested() || !isStreaming()) {
            return
        }
        val location = synchronized(lock) { latestLocation?.let { Location(it) } }
        if (location == null) {
            enqueueStreamError("Waiting for a live GPS fix.")
            scheduleResend()
            return
        }
        if (!isFresh(location, LOCATION_STALE_FOR_UI_MILLIS)) {
            enqueueStreamError("Location fix is stale.")
            scheduleResend()
            return
        }
        sendGpsUpdate(location, force = true)
        notifyStatusChanged()
        scheduleResend()
    }

    private fun sendGpsUpdate(location: Location, force: Boolean): Boolean {
        val (worldX, worldY) = worldPoint(location.latitude, location.longitude)
        val heading = headingDegrees(location)
        val shouldSend = synchronized(lock) {
            force || shouldSendGpsUpdateLocked(worldX, worldY, heading, System.currentTimeMillis())
        }
        if (!shouldSend) {
            return false
        }
        synchronized(lock) {
            lastGpsSentWorldX = worldX
            lastGpsSentWorldY = worldY
            lastGpsSentHeading = heading
            lastGpsSentAtMillis = System.currentTimeMillis()
        }
        synchronized(lock) { bridge }?.enqueue(gpsMessage(location, nextGpsSequence()))
        return true
    }

    private fun shouldSendGpsUpdateLocked(worldX: Int, worldY: Int, heading: Int, nowMillis: Long): Boolean {
        val lastWorldX = lastGpsSentWorldX
        val lastWorldY = lastGpsSentWorldY
        val lastHeading = lastGpsSentHeading
        val positionChanged = lastWorldX == null || lastWorldY == null ||
            lastWorldX != worldX || lastWorldY != worldY
        val headingChanged = heading != -1 &&
            (lastHeading == null || lastHeading == -1 ||
                headingDeltaDegrees(lastHeading, heading) >= GPS_STREAM_HEADING_DELTA_DEGREES)
        val intervalElapsed = lastGpsSentAtMillis == 0L ||
            nowMillis - lastGpsSentAtMillis >= GPS_STREAM_MAX_INTERVAL_MILLIS
        return positionChanged || headingChanged || intervalElapsed
    }

    private fun enqueueStreamError(text: String) {
        val nowMillis = System.currentTimeMillis()
        val shouldSend = synchronized(lock) {
            val shouldEmit = text != lastGpsStreamErrorText ||
                nowMillis - lastGpsStreamErrorAtMillis >= GPS_STREAM_ERROR_INTERVAL_MILLIS
            if (shouldEmit) {
                lastGpsStreamErrorText = text
                lastGpsStreamErrorAtMillis = nowMillis
            }
            shouldEmit
        }
        if (!shouldSend) {
            return
        }
        synchronized(lock) { bridge }?.enqueue(errorMessage(ERROR_LOCATION_UNAVAILABLE, CMD_GPS, text))
        synchronized(lock) { onStreamError }?.invoke(text)
        notifyStatusChanged()
    }

    private fun notifyStatusChanged() {
        val callback = synchronized(lock) { onStatusChanged } ?: return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            callback()
        } else {
            mainHandler.post { callback() }
        }
    }

    private fun scheduleResend() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post { scheduleResend() }
            return
        }
        mainHandler.removeCallbacks(resendRunnable)
        if (isRequested() && isStreaming()) {
            mainHandler.postDelayed(resendRunnable, GPS_STREAM_MAX_INTERVAL_MILLIS)
        }
    }

    private fun fusedRequest(): LocationRequest =
        LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, GPS_STREAM_MIN_INTERVAL_MILLIS)
            .setMinUpdateIntervalMillis(GPS_STREAM_FASTEST_INTERVAL_MILLIS)
            .setMinUpdateDistanceMeters(GPS_STREAM_MIN_DISTANCE_METERS)
            .setWaitForAccurateLocation(false)
            .build()

    private fun currentLocationRequest(): CurrentLocationRequest =
        CurrentLocationRequest.Builder()
            .setPriority(Priority.PRIORITY_HIGH_ACCURACY)
            .setMaxUpdateAgeMillis(LOCATION_FRESH_MILLIS)
            .build()

    private fun gpsFixCandidate(location: Location): GpsFixCandidate =
        GpsFixCandidate(
            latitude = location.latitude,
            longitude = location.longitude,
            provider = location.provider,
            wallTimeMillis = location.time,
            elapsedRealtimeNanos = location.elapsedRealtimeNanos,
            accuracyMeters = if (location.hasAccuracy()) location.accuracy else null
        )

    private fun gpsMessage(location: Location, sequence: Int): Map<String, Any?> {
        val (worldX, worldY) = worldPoint(location.latitude, location.longitude)
        val heading = headingDegrees(location)
        return watchMessage(
            CMD_GPS,
            linkedMapOf(
                KEY_WORLD_X to worldX,
                KEY_WORLD_Y to worldY,
                KEY_TILE_ZOOM to ROUTE_WORLD_ZOOM,
                KEY_BUTTON_ID to heading,
                KEY_GPS_SEQUENCE to sequence,
                KEY_GPS_ELAPSED_MS to gpsElapsedRealtimeMillis(location),
                KEY_GPS_ACCURACY_CM to gpsAccuracyCentimeters(location),
                KEY_GPS_PROVIDER to gpsProvider(location)
            )
        )
    }

    private fun errorMessage(category: Int, failedCommand: Int, text: String): Map<String, Any?> =
        watchMessage(
            CMD_ERROR_STATE,
            linkedMapOf(
                KEY_BUTTON_ID to category,
                KEY_CHUNK_INDEX to failedCommand,
                KEY_CHUNK_OFFSET to 0,
                KEY_INSTRUCTION to text.take(MAX_WATCH_TEXT_CHARS)
            )
        )

    private fun nextGpsSequence(): Int =
        synchronized(lock) {
            val elapsedSequence = gpsSequenceFromElapsedRealtime()
            val next = if (elapsedSequence > lastGpsSequence) {
                elapsedSequence
            } else if (lastGpsSequence >= Int.MAX_VALUE - 1) {
                Int.MAX_VALUE
            } else {
                lastGpsSequence + 1
            }
            lastGpsSequence = if (next <= 0) 1 else next
            lastGpsSequence
        }

    private fun initialGpsSequence(): Int =
        gpsSequenceFromElapsedRealtime().coerceAtLeast(1)

    private fun gpsSequenceFromElapsedRealtime(): Int {
        val elapsedSixteenths = SystemClock.elapsedRealtime() / GPS_SEQUENCE_SLOT_MILLIS
        return elapsedSixteenths.coerceAtMost((Int.MAX_VALUE - 1).toLong()).toInt()
    }

    private fun gpsElapsedRealtimeMillis(location: Location): Int {
        val elapsedMillis = location.elapsedRealtimeNanos / 1_000_000L
        return elapsedMillis.coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
    }

    private fun gpsAccuracyCentimeters(location: Location): Int =
        if (location.hasAccuracy()) {
            (location.accuracy * 100f).roundToInt().coerceAtLeast(0)
        } else {
            -1
        }

    private fun gpsProvider(location: Location): String =
        (location.provider ?: "fused").take(MAX_GPS_PROVIDER_CHARS)

    private fun headingDegrees(location: Location): Int =
        if (location.hasBearing()) {
            location.bearing.roundToInt().floorMod(360)
        } else {
            -1
        }

    private fun headingDeltaDegrees(previous: Int, next: Int): Int {
        val raw = kotlin.math.abs(previous.floorMod(360) - next.floorMod(360))
        return kotlin.math.min(raw, 360 - raw)
    }

    private fun isFresh(location: Location, thresholdMillis: Long): Boolean =
        System.currentTimeMillis() - location.time <= thresholdMillis

    private fun locationPayload(location: Location): Map<String, Any?> =
        mapOf(
            "latitude" to location.latitude,
            "longitude" to location.longitude,
            "accuracyMeters" to if (location.hasAccuracy()) location.accuracy.toDouble() else null,
            "timestampMillis" to location.time,
            "provider" to gpsProvider(location),
            "isFresh" to isFresh(location, LOCATION_STALE_FOR_UI_MILLIS)
        )

    fun locationPayloadFor(location: Location): Map<String, Any?> = locationPayload(location)

    fun gpsMessageFor(location: Location): Map<String, Any?> =
        gpsMessage(location, nextGpsSequence())

    private fun Int.floorMod(modulus: Int): Int = ((this % modulus) + modulus) % modulus

    private const val LOCATION_FRESH_MILLIS = 15_000L
    private const val LOCATION_STALE_FOR_UI_MILLIS = 60_000L
    private const val LOCATION_REQUEST_TIMEOUT_MILLIS = 8_000L
    private const val GPS_STREAM_MIN_INTERVAL_MILLIS = 1_000L
    private const val GPS_STREAM_FASTEST_INTERVAL_MILLIS = 500L
    private const val GPS_STREAM_MAX_INTERVAL_MILLIS = 4_000L
    private const val GPS_STREAM_ERROR_INTERVAL_MILLIS = 30_000L
    private const val GPS_STREAM_MIN_DISTANCE_METERS = 1.0f
    private const val GPS_STREAM_HEADING_DELTA_DEGREES = 5
    private const val GPS_SEQUENCE_SLOT_MILLIS = 62L
    private const val MAX_GPS_PROVIDER_CHARS = 15
    private const val MAX_WATCH_TEXT_CHARS = 47
    private const val ERROR_LOCATION_UNAVAILABLE = 3
}
