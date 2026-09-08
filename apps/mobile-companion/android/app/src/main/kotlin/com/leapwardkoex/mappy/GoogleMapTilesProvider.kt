package com.leapwardkoex.mappy

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.SocketTimeoutException
import java.net.URLEncoder
import java.util.LinkedHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.math.tan

interface SourceTileRaster {
    val width: Int
    val height: Int
    fun getPixel(x: Int, y: Int): Int
    fun readPixels(): IntArray = IntArray(width * height) { getPixel(it % width, it / width) }
    fun recycle() {}
}

interface SourceTileDecoder {
    fun decode(bytes: ByteArray): SourceTileRaster?
}

class AndroidSourceTileDecoder : SourceTileDecoder {
    override fun decode(bytes: ByteArray): SourceTileRaster? =
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { bitmap ->
            AndroidBitmapSourceTileRaster(bitmap)
        }
}

private class AndroidBitmapSourceTileRaster(
    private val bitmap: Bitmap
) : SourceTileRaster {
    override val width: Int
        get() = bitmap.width
    override val height: Int
        get() = bitmap.height

    override fun getPixel(x: Int, y: Int): Int = bitmap.getPixel(x, y)
    override fun readPixels(): IntArray = IntArray(width * height).also {
        bitmap.getPixels(it, 0, width, 0, 0, width, height)
    }

    override fun recycle() {
        if (!bitmap.isRecycled) {
            bitmap.recycle()
        }
    }
}

class GoogleMapTilesProvider(
    keyStore: GoogleCredentialStore,
    private val identityProvider: AndroidIdentityProvider,
    private val httpClient: GoogleHttpClient = UrlGoogleHttpClient(),
    private val binaryStringEncoder: BinaryStringEncoder = AndroidBase64StringEncoder(),
    private val sourceTileDecoder: SourceTileDecoder = AndroidSourceTileDecoder(),
    private val allowUnrestrictedDevelopmentKey: () -> Boolean = { false },
    private val sourceExecutor: ExecutorService = Executors.newFixedThreadPool(4) { task ->
        Thread(task, "mappy-source-tile").apply { isDaemon = true }
    },
    private val apiUsage: ApiUsageTracker? = null
) {
    constructor(
        context: Context,
        keyStore: ApiKeyStore,
        allowUnrestrictedDevelopmentKey: () -> Boolean = { false },
        apiUsage: ApiUsageTracker
    ) : this(
        keyStore = keyStore,
        identityProvider = RuntimeAndroidIdentityProvider(context),
        httpClient = UrlGoogleHttpClient(),
        binaryStringEncoder = AndroidBase64StringEncoder(),
        allowUnrestrictedDevelopmentKey = allowUnrestrictedDevelopmentKey,
        apiUsage = apiUsage
    )

    private val credentialLifecycleLock = Any()
    private val delegateKeyStore = keyStore
    private val keyStore: GoogleCredentialStore = object : GoogleCredentialStore by delegateKeyStore {
        override fun markValidationResult(
            validationState: String,
            validationDetail: String?,
            httpStatus: Int?,
            packageName: String,
            certSha1: String
        ): Map<String, Any?> =
            synchronized(credentialLifecycleLock) {
                ensureProviderOperationCurrent()
                delegateKeyStore.markValidationResult(
                    validationState,
                    validationDetail,
                    httpStatus,
                    packageName,
                    certSha1
                )
            }
    }

    @Volatile
    private var cachedSession: TileSession? = null
    private val sessionLock = Any()
    private val sourceTileCache = boundedCache<String, ByteArray>(MAX_SOURCE_TILE_CACHE_ENTRIES)
    private val encodedWatchTileCache = boundedCache<String, EncodedWatchTile>(MAX_WATCH_TILE_CACHE_ENTRIES)
    private val sourcePixelCache = SourcePixelCache()
    private val sourceJobs = SharedTileJobs<String, LoadedSource>()
    private val renderJobs = SharedTileJobs<String, PreparedWatchTile>()
    private val sessionJobs = SharedTileJobs<String, TileSession>()
    private val providerOperationGeneration = AtomicLong(0L)
    @Volatile private var closed = false
    private val threadOperationGeneration = ThreadLocal<Long>()
    @Volatile
    private var mapTileSettings = MapTileSettings()

    fun clearProviderSessions() = synchronized(credentialLifecycleLock) {
        invalidateProviderOperationsAndClearSessions()
    }

    fun <T> mutateCredentialState(mutation: () -> T): T =
        synchronized(credentialLifecycleLock) {
            invalidateProviderOperationsAndClearSessions()
            mutation()
        }

    private fun invalidateProviderOperationsAndClearSessions() {
        providerOperationGeneration.incrementAndGet()
        httpClient.cancelAll()
        synchronized(sessionLock) { cachedSession = null }
        synchronized(sourceTileCache) { sourceTileCache.clear() }
        synchronized(encodedWatchTileCache) { encodedWatchTileCache.clear() }
        sourcePixelCache.clear()
        cancelTileWork()
    }

    fun cancelTileWork() {
        renderJobs.cancelAll()
        sourceJobs.cancelAll()
        sessionJobs.cancelAll()
    }

    fun close() {
        synchronized(credentialLifecycleLock) {
            if (closed) return
            closed = true
            invalidateProviderOperationsAndClearSessions()
        }
        sourceExecutor.shutdownNow()
    }

    private fun <T> withOperationGeneration(generation: Long, action: () -> T): T {
        val previous = threadOperationGeneration.get()
        threadOperationGeneration.set(generation)
        return try {
            ensureProviderOperationCurrent()
            action()
        } finally {
            if (previous == null) threadOperationGeneration.remove() else threadOperationGeneration.set(previous)
        }
    }

    private fun keyForProviderOperation(): String? =
        synchronized(credentialLifecycleLock) {
            if (closed) throw ProviderOperationCancelledException()
            val generation = providerOperationGeneration.get()
            threadOperationGeneration.set(generation)
            val key = keyStore.getPlaintextKey()
            ensureProviderOperationCurrent()
            key
        }

    private fun ensureProviderOperationCurrent() {
        val generation = threadOperationGeneration.get()
            ?: throw ProviderOperationCancelledException()
        if (closed || generation != providerOperationGeneration.get()) {
            throw ProviderOperationCancelledException()
        }
    }

    internal fun operationGenerationForCurrentThread(): Long? =
        threadOperationGeneration.get()

    internal fun runIfProviderOperationCurrent(
        generation: Long?,
        action: () -> Unit
    ): Boolean {
        if (generation == null) return false
        return synchronized(credentialLifecycleLock) {
            if (generation != providerOperationGeneration.get()) {
                false
            } else {
                action()
                true
            }
        }
    }

    private fun executeProviderRequest(
        request: GoogleHttpRequest,
        product: ApiProduct,
        units: Long = 1,
        cancellation: TileCancellationToken? = null
    ): GoogleHttpResponse {
        val generation = threadOperationGeneration.get()
            ?: throw ProviderOperationCancelledException()
        ensureProviderOperationCurrent()
        cancellation?.throwIfCancelled()
        apiUsage?.reserve(product, units)
        return httpClient.execute(request, {
            generation != providerOperationGeneration.get()
        }, cancellation)
    }

    fun clearProviderValidationCache(): Map<String, Any?> {
        clearProviderSessions()
        return keyStore.clearValidationStatus()
    }

    fun providerStatus(): Map<String, Any?> {
        val identity = identityProvider.currentIdentity()
        return keyStore.getStatus() + mapOf(
            "packageName" to identity.packageName,
            "certSha1" to identity.certSha1
        )
    }

    fun mapTileSettingsStatus(): Map<String, Any?> =
        mapOf(
            "ok" to true,
            "providerStatus" to providerStatus(),
            "settings" to mapTileSettings.asMap(),
            "detail" to "Map tile settings loaded."
        )

    fun currentMapTileSettings(): MapTileSettings = mapTileSettings

    fun updateMapTileSettings(settings: MapTileSettings): Map<String, Any?> {
        val changed = setMapTileSettings(settings)
        return mapOf(
            "ok" to true,
            "providerStatus" to providerStatus(),
            "settings" to mapTileSettings.asMap(),
            "changed" to changed,
            "detail" to if (changed) {
                "Map tile settings updated; tile caches were cleared."
            } else {
                "Map tile settings unchanged."
            }
        )
    }

    fun setMapTileSettings(settings: MapTileSettings, clearCaches: Boolean = true): Boolean =
        synchronized(credentialLifecycleLock) {
            val changed = mapTileSettings != settings
            mapTileSettings = settings
            if (changed && clearCaches) invalidateProviderOperationsAndClearSessions()
            changed
        }

    fun validateProviderSetup(): Map<String, Any?> = try {
        validateProviderSetupUnchecked()
    } catch (blocked: ApiUsageBlockedException) {
        keyStore.getStatus() + mapOf("validationDetail" to blocked.message, "usageBlocked" to true)
    }

    private inline fun usageGuard(action: () -> Map<String, Any?>): Map<String, Any?> = try {
        action()
    } catch (blocked: ApiUsageBlockedException) {
        operationFailure(keyStore.getStatus(), blocked.message.orEmpty(), ERROR_ROUTE_PROVIDER) +
            mapOf("usageBlockReason" to blocked.reason)
    }

    fun previewTile(latitude: Double, longitude: Double, zoom: Int): Map<String, Any?> =
        usageGuard { previewTileUnchecked(latitude, longitude, zoom) }

    fun geocodeDestination(addressText: String, language: String, region: String): Map<String, Any?> =
        usageGuard { geocodeDestinationUnchecked(addressText, language, region) }

    fun autocompleteDestination(input: String, originLatitude: Double?, originLongitude: Double?,
        sessionToken: String?, language: String, region: String): Map<String, Any?> = usageGuard {
        autocompleteDestinationUnchecked(input, originLatitude, originLongitude, sessionToken, language, region)
    }

    fun resolvePlace(placeId: String, sessionToken: String?, language: String, region: String): Map<String, Any?> =
        usageGuard { resolvePlaceUnchecked(placeId, sessionToken, language, region) }

    fun computeRoute(originLatitude: Double, originLongitude: Double, destinationAddress: String?,
        destinationLatitude: Double?, destinationLongitude: Double?, travelMode: String,
        language: String, region: String): Map<String, Any?> = usageGuard {
        computeRouteUnchecked(originLatitude, originLongitude, destinationAddress, destinationLatitude,
            destinationLongitude, travelMode, language, region)
    }

    private fun validateProviderSetupUnchecked(): Map<String, Any?> {
        val key = keyForProviderOperation()
        val identity = identityProvider.currentIdentity()
        return validateProviderSetupForOperation(key, identity)
    }

    private fun validateProviderSetupForOperation(
        key: String?,
        identity: AndroidIdentity
    ): Map<String, Any?> {
        if (key.isNullOrBlank()) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_NOT_CONFIGURED,
                "No Google API key is stored.",
                null,
                identity.packageName,
                identity.certSha1
            )
        }

        val tiles = validateMapTiles(key, identity)
        if (tiles != null) {
            synchronized(sessionLock) { cachedSession = null }
            return tiles
        }

        val geocoding = validateGeocoding(key, identity)
        if (geocoding != null) {
            return geocoding
        }

        val places = validatePlaces(key, identity)
        if (places != null) {
            return places
        }

        val routes = validateRoutes(key, identity)
        if (routes != null) {
            return routes
        }

        return keyStore.markValidationResult(
            ApiKeyStore.STATE_VALID,
            "Map Tiles, Places, Geocoding, and Routes validation succeeded.",
            200,
            identity.packageName,
            identity.certSha1
        )
    }

    private fun previewTileUnchecked(latitude: Double, longitude: Double, zoom: Int): Map<String, Any?> {
        val key = keyForProviderOperation()
        val identity = identityProvider.currentIdentity()
        if (key.isNullOrBlank()) {
            return providerFailure(
                state = ApiKeyStore.STATE_NOT_CONFIGURED,
                detail = "No Google API key is stored.",
                httpStatus = null,
                identity = identity,
                errorCategory = ERROR_MISSING_KEY
            )
        }

        val status = keyStore.getStatus()
        val validationState = status["validationState"] as? String
        val settings = mapTileSettings
        if (validationState != ApiKeyStore.STATE_VALID) {
            return mapOf(
                "ok" to false,
                "providerStatus" to status,
                "detail" to status["validationDetail"],
                "errorCategory" to providerStateToCategory(validationState),
                "httpStatus" to status["validationHttpStatus"]
            )
        }

        ensureTileSession(key, identity)?.let { return it }

        val session = cachedSession
            ?: return providerFailure(
                state = ApiKeyStore.STATE_NETWORK_UNAVAILABLE,
                detail = "No Map Tiles session is available.",
                httpStatus = null,
                identity = identity,
                errorCategory = ERROR_NETWORK
            )
        val coordinate = tileCoordinate(latitude, longitude, zoom)
        val response = fetchTile(key, identity, session.sessionToken, coordinate)

        if (!response.success || response.bytes == null) {
            return mapOf(
                "ok" to false,
                "providerStatus" to keyStore.markValidationResult(
                    mapHttpStatusToState(response.httpStatus),
                    response.safeDetail,
                    response.httpStatus,
                    identity.packageName,
                    identity.certSha1
                ),
                "detail" to response.safeDetail,
                "errorCategory" to ERROR_TILE_PROVIDER,
                "httpStatus" to response.httpStatus
            )
        }

        return mapOf(
            "ok" to true,
            "providerStatus" to keyStore.getStatus(),
            "imageBase64" to binaryStringEncoder.encode(response.bytes),
            "tileX" to coordinate.tileX,
            "tileY" to coordinate.tileY,
            "zoom" to coordinate.zoom,
            "markerOffsetX" to scaledOffset(coordinate.offsetX, session.tileWidth),
            "markerOffsetY" to scaledOffset(coordinate.offsetY, session.tileHeight),
            "tileWidth" to session.tileWidth,
            "tileHeight" to session.tileHeight,
            "mapTileSettings" to settings.asMap(),
            "attribution" to "Google Map Tiles"
        )
    }

    private data class WatchOperation(
        val generation: Long,
        val key: String,
        val identity: AndroidIdentity,
        val settings: MapTileSettings
    )

    private data class LoadedSource(
        val pixels: SourceTilePixels,
        val fetchMillis: Double = 0.0,
        val decodeMillis: Double = 0.0,
        val sourceByteCacheHits: Int = 0,
        val sourcePixelCacheHits: Int = 0,
        val sourceRetries: Int = 0
    )

    private data class PreparedWatchTile(
        val encoded: EncodedWatchTile,
        val metrics: Map<String, Any>
    )

    private class SourcePreparationException(
        val response: ProviderResponse,
        val changesProviderStatus: Boolean = true
    ) : Exception(response.safeDetail)

    fun watchTile(
        worldX: Int,
        worldY: Int,
        zoom: Int,
        cancellation: TileCancellationToken = TileCancellationToken()
    ): Map<String, Any?> = watchTilePreparation(worldX, worldY, zoom, cancellation).toMap()

    internal fun watchTilePreparation(
        worldX: Int,
        worldY: Int,
        zoom: Int,
        cancellation: TileCancellationToken = TileCancellationToken()
    ): WatchTilePreparation = try {
        watchTilePreparationUnchecked(worldX, worldY, zoom, cancellation)
    } catch (blocked: ApiUsageBlockedException) {
        watchTileFailure(keyStore.getStatus(), blocked.message.orEmpty(), ERROR_TILE_PROVIDER, worldX, worldY, zoom)
    }

    private fun watchTilePreparationUnchecked(
        worldX: Int,
        worldY: Int,
        zoom: Int,
        cancellation: TileCancellationToken
    ): WatchTilePreparation {
        val started = System.nanoTime()
        cancellation.throwIfCancelled()
        val key = keyForProviderOperation()
        val identity = identityProvider.currentIdentity()
        if (key.isNullOrBlank()) {
            return watchTileFailure(
                keyStore.markValidationResult(ApiKeyStore.STATE_NOT_CONFIGURED, "No Google API key is stored.",
                    null, identity.packageName, identity.certSha1),
                "No Google API key is stored.", ERROR_MISSING_KEY, worldX, worldY, zoom
            )
        }
        val operation = synchronized(credentialLifecycleLock) {
            ensureProviderOperationCurrent()
            WatchOperation(threadOperationGeneration.get()!!, key, identity, mapTileSettings)
        }
        val status = keyStore.getStatus()
        if (status["validationState"] != ApiKeyStore.STATE_VALID) {
            return watchTileFailure(status, status["validationDetail"] as? String ?: "Provider setup is not valid.",
                providerStateToCategory(status["validationState"] as? String), worldX, worldY, zoom,
                status["validationHttpStatus"] as? Int)
        }
        val settings = operation.settings
        val safeZoom = zoom.coerceIn(0, MAX_WATCH_TILE_ZOOM)
        val worldSize = (1 shl safeZoom) * SOURCE_TILE_SIZE_INT
        val cropX = worldX.floorMod(worldSize)
        val cropY = worldY.coerceIn(0, worldSize - settings.watchTileHeight)
        val cacheKey = "${operation.generation}:${settings.cacheKey}:$cropX:$cropY:$safeZoom"
        synchronized(encodedWatchTileCache) { encodedWatchTileCache[cacheKey] }?.let {
            cancellation.throwIfCancelled()
            ensureProviderOperationCurrent()
            return watchTileSuccess(cropX, cropY, safeZoom, settings.watchTileWidth, settings.watchTileHeight,
                it, "encodedCache", mapOf("encodedCacheHits" to 1, "preparationMillis" to elapsedMillis(started)))
        }
        val lease = renderJobs.acquire(cacheKey, cancellation)
        try {
            lease.runIfOwner { sharedCancellation ->
                withOperationGeneration(operation.generation) {
                    synchronized(encodedWatchTileCache) { encodedWatchTileCache[cacheKey] }?.let {
                        return@withOperationGeneration PreparedWatchTile(it, mapOf("encodedCacheHits" to 1))
                    }
                    sharedCancellation.throwIfCancelled()
                    val sessionStarted = System.nanoTime()
                    val session = watchTileSession(operation, sharedCancellation)
                    val sessionMillis = elapsedMillis(sessionStarted)
                    prepareWatchTile(operation, session, cropX, cropY, safeZoom, worldSize, sharedCancellation)
                        .let { it.copy(metrics = it.metrics + ("sessionMillis" to sessionMillis)) }
                        .also { prepared ->
                            synchronized(credentialLifecycleLock) {
                                ensureProviderOperationCurrent()
                                sharedCancellation.throwIfCancelled()
                                synchronized(encodedWatchTileCache) { encodedWatchTileCache[cacheKey] = prepared.encoded }
                            }
                        }
                }
            }
            val prepared = lease.await()
            ensureProviderOperationCurrent()
            return watchTileSuccess(cropX, cropY, safeZoom, settings.watchTileWidth, settings.watchTileHeight,
                prepared.encoded, if (lease.isOwner) "rendered" else "duplicateInFlight",
                prepared.metrics + mapOf("preparationMillis" to elapsedMillis(started),
                    "sharedRenderHits" to if (lease.isOwner) 0 else 1))
        } catch (failure: SourcePreparationException) {
            cancellation.throwIfCancelled()
            ensureProviderOperationCurrent()
            val response = failure.response
            val failureStatus = if (failure.changesProviderStatus) {
                keyStore.markValidationResult(mapHttpStatusToState(response.httpStatus), response.safeDetail,
                    response.httpStatus, identity.packageName, identity.certSha1)
            } else keyStore.getStatus()
            return watchTileFailure(failureStatus, response.safeDetail, ERROR_TILE_PROVIDER,
                cropX, cropY, safeZoom, response.httpStatus)
        } finally {
            lease.close()
        }
    }

    private fun prepareWatchTile(
        operation: WatchOperation,
        session: TileSession,
        cropX: Int,
        cropY: Int,
        zoom: Int,
        worldSize: Int,
        cancellation: TileCancellationToken
    ): PreparedWatchTile {
        val width = operation.settings.watchTileWidth
        val height = operation.settings.watchTileHeight
        val keys = sourceTilesForCrop(cropX, cropY, zoom, worldSize, width, height).toList()
        val leases = ArrayList<SharedTileJobs<String, LoadedSource>.Lease>(keys.size)
        val waitingStarted = System.nanoTime()
        try {
            for ((x, y) in keys) {
                cancellation.throwIfCancelled()
                ensureProviderOperationCurrent()
                val cacheKey = "${operation.generation}:${operation.settings.cacheKey}:$zoom:$x:$y"
                val lease = sourceJobs.acquire(cacheKey, cancellation)
                leases.add(lease)
                lease.submitIfOwner(sourceExecutor) { sourceCancellation ->
                    withOperationGeneration(operation.generation) {
                        loadSourceTile(operation, session, TileCoordinate(x, y, zoom, 0.0, 0.0),
                            cacheKey, sourceCancellation)
                    }
                }
            }
            val sources = leases.map { it.await() }
            val waitMillis = elapsedMillis(waitingStarted)
            cancellation.throwIfCancelled()
            val cropStarted = System.nanoTime()
            val colors = IntArray(width * height)
            val sourceXs = IntArray(width) { (cropX + it).floorMod(worldSize) / SOURCE_TILE_SIZE_INT }
            val logicalXs = IntArray(width) { (cropX + it).floorMod(worldSize) % SOURCE_TILE_SIZE_INT }
            val sampledXs = sources.map { source ->
                IntArray(width) { scaledSourcePixel(logicalXs[it], source.pixels.width) }
            }
            for (y in 0 until height) {
                cancellation.throwIfCancelled()
                val sourceWorldY = (cropY + y).coerceIn(0, worldSize - 1)
                val sourceY = sourceWorldY / SOURCE_TILE_SIZE_INT
                val logicalY = sourceWorldY % SOURCE_TILE_SIZE_INT
                for (sourceIndex in keys.indices) {
                    if (keys[sourceIndex].second != sourceY) continue
                    val pixels = sources[sourceIndex].pixels
                    val row = scaledSourcePixel(logicalY, pixels.height) * pixels.width
                    val tileX = keys[sourceIndex].first
                    for (x in 0 until width) {
                        if (sourceXs[x] == tileX) {
                            colors[y * width + x] = pixels.pixels[row + sampledXs[sourceIndex][x]]
                        }
                    }
                }
            }
            val cropMillis = elapsedMillis(cropStarted)
            val colorStarted = System.nanoTime()
            val indexes = ByteArray(colors.size)
            for (y in 0 until height) {
                cancellation.throwIfCancelled()
                for (x in 0 until width) {
                    val offset = y * width + x
                    indexes[offset] = DayTileColors.paletteIndex(colors[offset]).toByte()
                }
            }
            val colorMillis = elapsedMillis(colorStarted)
            cancellation.throwIfCancelled()
            val encodeStarted = System.nanoTime()
            val encoded = WatchTileEncoder.encode(indexes, width, height)
            val encodeMillis = elapsedMillis(encodeStarted)
            cancellation.throwIfCancelled()
            return PreparedWatchTile(encoded, mapOf(
                "sourceWaitMillis" to waitMillis,
                "fetchMillis" to sources.sumOf { it.fetchMillis },
                "decodeMillis" to sources.sumOf { it.decodeMillis },
                "cropMillis" to cropMillis, "colorMillis" to colorMillis, "encodeMillis" to encodeMillis,
                "sourceByteCacheHits" to sources.sumOf { it.sourceByteCacheHits },
                "sourcePixelCacheHits" to sources.sumOf { it.sourcePixelCacheHits },
                "sharedSourceHits" to leases.count { !it.isOwner },
                "sourceTiles" to sources.size,
                "sourceRetries" to sources.sumOf { it.sourceRetries },
                "payloadBytes" to encoded.payload.size
            ))
        } finally {
            leases.forEach { it.close() }
        }
    }

    private fun loadSourceTile(
        operation: WatchOperation,
        initialSession: TileSession,
        coordinate: TileCoordinate,
        cacheKey: String,
        cancellation: TileCancellationToken
    ): LoadedSource {
        cancellation.throwIfCancelled()
        sourcePixelCache.get(cacheKey)?.let { return LoadedSource(it, sourcePixelCacheHits = 1) }
        val cachedBytes = synchronized(sourceTileCache) { sourceTileCache[cacheKey] }
        val fetchStarted = System.nanoTime()
        var sourceRetries = 0
        val bytes = cachedBytes ?: run {
            var response = fetchTile(operation.key, operation.identity, initialSession.sessionToken, coordinate, cancellation)
            if (!response.success && response.httpStatus in setOf(400, 401, 403, 404)) {
                cancellation.throwIfCancelled()
                val replacement = watchTileSession(operation, cancellation, initialSession.sessionToken)
                cancellation.throwIfCancelled()
                sourceRetries++
                response = fetchTile(operation.key, operation.identity, replacement.sessionToken, coordinate, cancellation)
            }
            if (!response.success || response.bytes == null) throw SourcePreparationException(response)
            response.bytes.also {
                synchronized(credentialLifecycleLock) {
                    ensureProviderOperationCurrent()
                    cancellation.throwIfCancelled()
                    synchronized(sourceTileCache) { sourceTileCache[cacheKey] = it }
                }
            }
        }
        val fetchMillis = if (cachedBytes == null) elapsedMillis(fetchStarted) else 0.0
        cancellation.throwIfCancelled()
        val decodeStarted = System.nanoTime()
        val raster = sourceTileDecoder.decode(bytes) ?: run {
            synchronized(sourceTileCache) { sourceTileCache.remove(cacheKey) }
            throw SourcePreparationException(ProviderResponse(false, null, "Map tile image could not be decoded."), false)
        }
        val pixels = try {
            cancellation.throwIfCancelled()
            SourceTilePixels(raster.width, raster.height, raster.readPixels())
        } finally { raster.recycle() }
        val decodeMillis = elapsedMillis(decodeStarted)
        synchronized(credentialLifecycleLock) {
            ensureProviderOperationCurrent()
            cancellation.throwIfCancelled()
            sourcePixelCache.put(cacheKey, pixels)
        }
        return LoadedSource(pixels, fetchMillis, decodeMillis, if (cachedBytes == null) 0 else 1, sourceRetries = sourceRetries)
    }

    private fun watchTileSession(
        operation: WatchOperation,
        cancellation: TileCancellationToken,
        expiredToken: String? = null
    ): TileSession {
        fun reusable(): TileSession? = synchronized(sessionLock) {
            ensureProviderOperationCurrent()
            cachedSession?.takeIf {
                it.settingsKey == operation.settings.cacheKey && it.sessionToken != expiredToken
            }
        }
        cancellation.throwIfCancelled()
        reusable()?.let { return it }
        val jobKey = "${operation.generation}:${operation.settings.cacheKey}:${expiredToken ?: "initial"}"
        val lease = sessionJobs.acquire(jobKey, cancellation)
        try {
            lease.runIfOwner { sharedCancellation ->
                withOperationGeneration(operation.generation) {
                    reusable() ?: run {
                        sharedCancellation.throwIfCancelled()
                        val response = createSession(operation.key, operation.identity.packageName,
                            operation.identity.certSha1, operation.settings, sharedCancellation)
                        val session = response.session
                        if (!response.success || session == null) throw SourcePreparationException(response)
                        synchronized(credentialLifecycleLock) {
                            ensureProviderOperationCurrent()
                            sharedCancellation.throwIfCancelled()
                            synchronized(sessionLock) {
                                reusable() ?: session.also { cachedSession = it }
                            }
                        }
                    }
                }
            }
            return lease.await()
        } finally { lease.close() }
    }

    private fun elapsedMillis(started: Long): Double = (System.nanoTime() - started) / 1_000_000.0

    private fun geocodeDestinationUnchecked(addressText: String, language: String, region: String): Map<String, Any?> {
        val key = keyForProviderOperation()
        val identity = identityProvider.currentIdentity()
        val address = addressText.trim()
        if (key.isNullOrBlank()) {
            return providerFailure(
                state = ApiKeyStore.STATE_NOT_CONFIGURED,
                detail = "No Google API key is stored.",
                httpStatus = null,
                identity = identity,
                errorCategory = ERROR_MISSING_KEY
            )
        }
        if (address.isBlank()) {
            return operationFailure(
                status = keyStore.getStatus(),
                detail = "Destination address is empty.",
                errorCategory = ERROR_DESTINATION_NOT_CONFIGURED
            )
        }
        validationFailureIfProviderNotReady(key, identity)?.let { return it }

        val response = geocodeAddress(key, identity, address, language, region)
        if (!response.success || response.geocode == null) {
            return geocodeFailure(response, identity)
        }

        return mapOf(
            "ok" to true,
            "providerStatus" to keyStore.getStatus(),
            "latitude" to response.geocode.latitude,
            "longitude" to response.geocode.longitude,
            "formattedAddress" to response.geocode.formattedAddress,
            "placeId" to response.geocode.placeId,
            "provider" to "google_geocoding",
            "detail" to "Geocoding succeeded."
        )
    }

    private fun autocompleteDestinationUnchecked(
        input: String,
        originLatitude: Double?,
        originLongitude: Double?,
        sessionToken: String?,
        language: String,
        region: String
    ): Map<String, Any?> {
        val key = keyForProviderOperation()
        val identity = identityProvider.currentIdentity()
        val query = input.trim()
        if (key.isNullOrBlank()) {
            return providerFailure(
                state = ApiKeyStore.STATE_NOT_CONFIGURED,
                detail = "No Google API key is stored.",
                httpStatus = null,
                identity = identity,
                errorCategory = ERROR_MISSING_KEY
            )
        }
        if (query.isBlank()) {
            return operationFailure(
                status = keyStore.getStatus(),
                detail = "Destination search is empty.",
                errorCategory = ERROR_DESTINATION_NOT_CONFIGURED
            ) + mapOf("suggestions" to emptyList<Map<String, Any?>>())
        }
        validationFailureIfProviderNotReady(key, identity)?.let {
            return it + mapOf("suggestions" to emptyList<Map<String, Any?>>())
        }

        val response = autocompletePlaces(
            key = key,
            identity = identity,
            input = query,
            origin = originLatitude?.let { lat ->
                originLongitude?.let { lng -> LatLng(lat, lng) }
            },
            sessionToken = sessionToken,
            language = language,
            region = region
        )
        if (!response.success) {
            return geocodeFailure(response, identity) + mapOf("suggestions" to emptyList<Map<String, Any?>>())
        }

        return mapOf(
            "ok" to true,
            "providerStatus" to keyStore.getStatus(),
            "suggestions" to response.suggestions.map { it.asMap() },
            "detail" to "Autocomplete returned ${response.suggestions.size} suggestions.",
            "attribution" to "Google Places"
        )
    }

    private fun resolvePlaceUnchecked(
        placeId: String,
        sessionToken: String?,
        language: String,
        region: String
    ): Map<String, Any?> {
        val key = keyForProviderOperation()
        val identity = identityProvider.currentIdentity()
        val id = placeId.trim()
        if (key.isNullOrBlank()) {
            return providerFailure(
                state = ApiKeyStore.STATE_NOT_CONFIGURED,
                detail = "No Google API key is stored.",
                httpStatus = null,
                identity = identity,
                errorCategory = ERROR_MISSING_KEY
            )
        }
        if (id.isBlank()) {
            return operationFailure(
                status = keyStore.getStatus(),
                detail = "Place ID is empty.",
                errorCategory = ERROR_DESTINATION_NOT_CONFIGURED
            )
        }
        validationFailureIfProviderNotReady(key, identity)?.let { return it }

        val response = placeDetails(
            key = key,
            identity = identity,
            placeId = id,
            sessionToken = sessionToken,
            language = language,
            region = region
        )
        if (!response.success || response.geocode == null) {
            return geocodeFailure(response, identity)
        }

        return mapOf(
            "ok" to true,
            "providerStatus" to keyStore.getStatus(),
            "latitude" to response.geocode.latitude,
            "longitude" to response.geocode.longitude,
            "formattedAddress" to response.geocode.formattedAddress,
            "placeId" to response.geocode.placeId,
            "label" to response.geocode.label,
            "provider" to "google_places",
            "detail" to "Place resolved.",
            "attribution" to "Google Places"
        )
    }

    private fun computeRouteUnchecked(
        originLatitude: Double,
        originLongitude: Double,
        destinationAddress: String?,
        destinationLatitude: Double?,
        destinationLongitude: Double?,
        travelMode: String,
        language: String,
        region: String
    ): Map<String, Any?> {
        val key = keyForProviderOperation()
        val identity = identityProvider.currentIdentity()
        if (key.isNullOrBlank()) {
            return providerFailure(
                state = ApiKeyStore.STATE_NOT_CONFIGURED,
                detail = "No Google API key is stored.",
                httpStatus = null,
                identity = identity,
                errorCategory = ERROR_MISSING_KEY
            )
        }

        val hasCoordinateDestination = destinationLatitude != null && destinationLongitude != null
        val hasAddressDestination = !destinationAddress.isNullOrBlank()
        if (!hasCoordinateDestination && !hasAddressDestination) {
            return operationFailure(
                status = keyStore.getStatus(),
                detail = "Destination address is empty.",
                errorCategory = ERROR_DESTINATION_NOT_CONFIGURED
            )
        }
        validationFailureIfProviderNotReady(key, identity)?.let { return it }

        val destination = when {
            hasCoordinateDestination -> GeocodeResult(
                latitude = destinationLatitude,
                longitude = destinationLongitude,
                formattedAddress = destinationAddress?.trim().orEmpty(),
                placeId = null
            )
            hasAddressDestination -> {
                val geocode = geocodeAddress(key, identity, destinationAddress, language, region)
                if (!geocode.success || geocode.geocode == null) {
                    return geocodeFailure(geocode, identity)
                }
                geocode.geocode
            }
            else -> throw IllegalStateException("Destination guard failed.")
        }

        val mode = normalizedTravelMode(travelMode)
        val response = computeGoogleRoute(
            key = key,
            identity = identity,
            origin = LatLng(originLatitude, originLongitude),
            destination = LatLng(destination.latitude, destination.longitude),
            travelMode = mode,
            language = language
        )

        if (!response.success || response.route == null) {
            return routeFailure(response, identity)
        }

        val route = response.route
        return mapOf(
            "ok" to true,
            "providerStatus" to keyStore.getStatus(),
            "detail" to "Route computed.",
            "destinationLatitude" to destination.latitude,
            "destinationLongitude" to destination.longitude,
            "formattedAddress" to destination.formattedAddress,
            "placeId" to destination.placeId,
            "travelMode" to mode,
            "distanceMeters" to route.distanceMeters,
            "durationSeconds" to route.durationSeconds,
            "encodedPolyline" to route.encodedPolyline,
            "routePoints" to route.routePoints.map { it.asMap() },
            "fullRoutePoints" to route.fullRoutePoints.map { it.asMap() },
            "steps" to route.steps.map { it.asMap() },
            "routeWarning" to routeModeWarning(mode),
            "attribution" to "Google Routes"
        )
    }

    private fun validateMapTiles(
        key: String,
        identity: AndroidIdentity
    ): Map<String, Any?>? {
        var publishFailure: (() -> Map<String, Any?>)? = null
        synchronized(sessionLock) {
            val correct = createSession(key, identity.packageName, identity.certSha1)
            if (!correct.success) {
                publishFailure = {
                    keyStore.markValidationResult(
                        mapHttpStatusToState(correct.httpStatus),
                        correct.safeDetail,
                        correct.httpStatus,
                        identity.packageName,
                        identity.certSha1
                    )
                }
                return@synchronized
            }
            cachedSession = correct.session
            if (allowUnrestrictedDevelopmentKey()) {
                return null
            }

            val wrongPackage = createSession(key, "${identity.packageName}.wrong", identity.certSha1)
            if (wrongPackage.success) {
                publishFailure = {
                    keyStore.markValidationResult(
                        ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                        "Map Tiles accepted an intentionally wrong Android package header.",
                        wrongPackage.httpStatus,
                        identity.packageName,
                        identity.certSha1
                    )
                }
                return@synchronized
            }
            if (!isRestrictionRejection(wrongPackage)) {
                publishFailure = {
                    keyStore.markValidationResult(
                        ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                        "Map Tiles wrong-package validation did not produce an auth or permission rejection.",
                        wrongPackage.httpStatus,
                        identity.packageName,
                        identity.certSha1
                    )
                }
            }
        }
        return publishFailure?.invoke()
    }

    private fun validateGeocoding(key: String, identity: AndroidIdentity): Map<String, Any?>? {
        val correct = geocodeAddress(
            key = key,
            identity = identity,
            address = VALIDATION_ADDRESS,
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (!correct.success) {
            return keyStore.markValidationResult(
                mapGeocodingState(correct),
                "Geocoding validation failed: ${correct.safeDetail}",
                correct.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        if (allowUnrestrictedDevelopmentKey()) {
            return null
        }

        val wrongPackage = geocodeAddress(
            key = key,
            identity = identity.copy(packageName = "${identity.packageName}.wrong"),
            address = VALIDATION_ADDRESS,
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (wrongPackage.success) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Geocoding accepted an intentionally wrong Android package header.",
                wrongPackage.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        if (!isRestrictionRejection(wrongPackage)) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Geocoding wrong-package validation did not produce an auth or permission rejection.",
                wrongPackage.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }

        return null
    }

    private fun validatePlaces(key: String, identity: AndroidIdentity): Map<String, Any?>? {
        val sessionToken = "mappy-validation-${System.currentTimeMillis()}"
        val autocomplete = autocompletePlaces(
            key = key,
            identity = identity,
            input = "1600 Amphitheatre",
            origin = VALIDATION_ROUTE_ORIGIN,
            sessionToken = sessionToken,
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (!autocomplete.success) {
            return keyStore.markValidationResult(
                mapHttpStatusToState(autocomplete.httpStatus),
                "Places Autocomplete validation failed: ${autocomplete.safeDetail}",
                autocomplete.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }

        val validationPlaceId = autocomplete.suggestions.firstOrNull()?.placeId ?: VALIDATION_PLACE_ID
        val details = placeDetails(
            key = key,
            identity = identity,
            placeId = validationPlaceId,
            sessionToken = sessionToken,
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (!details.success) {
            return keyStore.markValidationResult(
                mapHttpStatusToState(details.httpStatus),
                "Places Details validation failed: ${details.safeDetail}",
                details.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        if (allowUnrestrictedDevelopmentKey()) {
            return null
        }

        val wrongIdentity = identity.copy(packageName = "${identity.packageName}.wrong")
        val wrongAutocomplete = autocompletePlaces(
            key = key,
            identity = wrongIdentity,
            input = "1600 Amphitheatre",
            origin = VALIDATION_ROUTE_ORIGIN,
            sessionToken = "mappy-validation-wrong-${System.currentTimeMillis()}",
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (wrongAutocomplete.success) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Places Autocomplete accepted an intentionally wrong Android package header.",
                wrongAutocomplete.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        if (!isRestrictionRejection(wrongAutocomplete)) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Places Autocomplete wrong-package validation did not produce an auth or permission rejection.",
                wrongAutocomplete.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }

        val wrongDetails = placeDetails(
            key = key,
            identity = wrongIdentity,
            placeId = validationPlaceId,
            sessionToken = null,
            language = DEFAULT_LANGUAGE,
            region = DEFAULT_REGION
        )
        if (wrongDetails.success) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Places Details accepted an intentionally wrong Android package header.",
                wrongDetails.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        if (!isRestrictionRejection(wrongDetails)) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Places Details wrong-package validation did not produce an auth or permission rejection.",
                wrongDetails.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }

        return null
    }

    private fun validateRoutes(key: String, identity: AndroidIdentity): Map<String, Any?>? {
        val correct = computeGoogleRoute(
            key = key,
            identity = identity,
            origin = VALIDATION_ROUTE_ORIGIN,
            destination = VALIDATION_ROUTE_DESTINATION,
            travelMode = TRAVEL_MODE_DRIVE,
            language = DEFAULT_LANGUAGE
        )
        if (!correct.success) {
            return keyStore.markValidationResult(
                mapHttpStatusToState(correct.httpStatus),
                "Routes validation failed: ${correct.safeDetail}",
                correct.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        if (allowUnrestrictedDevelopmentKey()) {
            return null
        }

        val wrongPackage = computeGoogleRoute(
            key = key,
            identity = identity.copy(packageName = "${identity.packageName}.wrong"),
            origin = VALIDATION_ROUTE_ORIGIN,
            destination = VALIDATION_ROUTE_DESTINATION,
            travelMode = TRAVEL_MODE_DRIVE,
            language = DEFAULT_LANGUAGE
        )
        if (wrongPackage.success) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Routes accepted an intentionally wrong Android package header.",
                wrongPackage.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        if (!isRestrictionRejection(wrongPackage)) {
            return keyStore.markValidationResult(
                ApiKeyStore.STATE_UNSUPPORTED_RESTRICTED_KEY_BEHAVIOR,
                "Routes wrong-package validation did not produce an auth or permission rejection.",
                wrongPackage.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }

        return null
    }

    private fun validationFailureIfProviderNotReady(
        key: String,
        identity: AndroidIdentity
    ): Map<String, Any?>? {
        ensureProviderOperationCurrent()
        val status = keyStore.getStatus()
        if (status["validationState"] == ApiKeyStore.STATE_VALID) {
            return null
        }

        // Keep readiness validation inside the caller's immutable credential context.
        // Calling the public entry point here would replace the thread generation and
        // could make the caller's already-captured key appear current after rotation.
        val validation = validateProviderSetupForOperation(key, identity)
        if (validation["validationState"] == ApiKeyStore.STATE_VALID) {
            return null
        }

        return mapOf(
            "ok" to false,
            "providerStatus" to validation,
            "detail" to validation["validationDetail"],
            "errorCategory" to providerStateToCategory(validation["validationState"] as? String),
            "httpStatus" to validation["validationHttpStatus"]
        ).filterValues { it != null }
    }

    private fun ensureTileSession(
        key: String,
        identity: AndroidIdentity,
        settings: MapTileSettings = mapTileSettings
    ): Map<String, Any?>? {
        ensureProviderOperationCurrent()
        val settingsKey = settings.cacheKey
        if (cachedSession?.settingsKey == settingsKey) return null
        val response = synchronized(sessionLock) {
            ensureProviderOperationCurrent()
            if (cachedSession?.settingsKey == settingsKey) return null
            val candidate = createSession(key, identity.packageName, identity.certSha1, settings)
            if (candidate.success && candidate.session != null) {
                ensureProviderOperationCurrent()
                cachedSession = candidate.session
                return null
            }
            cachedSession = null
            candidate
        }
        val state = mapHttpStatusToState(response.httpStatus)
        val providerStatus = keyStore.markValidationResult(
            state,
            response.safeDetail,
            response.httpStatus,
            identity.packageName,
            identity.certSha1
        )
        return mapOf(
            "ok" to false,
            "providerStatus" to providerStatus,
            "detail" to response.safeDetail,
            "errorCategory" to providerStateToCategory(state),
            "httpStatus" to response.httpStatus
        ).filterValues { it != null }
    }

    private fun createSession(
        key: String, packageName: String, certSha1: String, settings: MapTileSettings = mapTileSettings,
        cancellation: TileCancellationToken? = null
    ): ProviderResponse {
        val bodyJson = JSONObject()
            .put("mapType", settings.googleMapType)
            .put("language", DEFAULT_LANGUAGE)
            .put("region", DEFAULT_REGION)
            .put("scale", settings.googleScale)
            .put("highDpi", settings.highDpi)
        settings.googleImageFormat?.let { format ->
            bodyJson.put("imageFormat", format)
        }
        if (settings.googleLayerTypes.isNotEmpty()) {
            bodyJson.put("layerTypes", JSONArray(settings.googleLayerTypes))
        }
        settings.googleOverlay?.let { overlay ->
            bodyJson.put("overlay", overlay)
        }
        val body = bodyJson
            .toString()
            .toByteArray(Charsets.UTF_8)

        return try {
            val response = executeProviderRequest(
                GoogleHttpRequest(
                    url = "$MAP_TILES_BASE_URL/createSession?key=${encoded(key)}",
                    method = "POST",
                    headers = androidHeaders(packageName, certSha1) +
                        mapOf("Content-Type" to "application/json; charset=utf-8"),
                    body = body
                ),
                product = ApiProduct.MAP_TILES,
                units = 0,
                cancellation = cancellation
            )
            val httpStatus = response.httpStatus
            if (httpStatus in 200..299) {
                val json = JSONObject(response.bodyText)
                val tileWidth = json.optInt("tileWidth", 0)
                val tileHeight = json.optInt("tileHeight", 0)
                val sessionToken = json.optString("session", "")
                if (tileWidth <= 0 || tileHeight <= 0 || sessionToken.isBlank()) {
                    ProviderResponse(
                        success = false,
                        httpStatus = httpStatus,
                        safeDetail = "Unexpected Map Tiles session response."
                    )
                } else {
                    ProviderResponse(
                        success = true,
                        httpStatus = httpStatus,
                        safeDetail = "Map Tiles session created.",
                        session = TileSession(sessionToken, tileWidth, tileHeight, settings.cacheKey)
                    )
                }
            } else {
                ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = safeErrorDetail(response.bodyText, key)
                )
            }
        } catch (blocked: ApiUsageBlockedException) {
            throw blocked
        } catch (cancelled: ProviderOperationCancelledException) {
            throw cancelled
        } catch (_: SocketTimeoutException) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network timeout.")
        } catch (_: Exception) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network or provider request failed.")
        }
    }

    private fun fetchTile(
        key: String,
        identity: AndroidIdentity,
        sessionToken: String,
        coordinate: TileCoordinate,
        cancellation: TileCancellationToken? = null
    ): ProviderResponse {
        return try {
            val response = executeProviderRequest(
                GoogleHttpRequest(
                    url = "$MAP_TILES_BASE_URL/2dtiles/${coordinate.zoom}/${coordinate.tileX}/${coordinate.tileY}" +
                        "?session=${encoded(sessionToken)}&key=${encoded(key)}",
                    headers = androidHeaders(identity.packageName, identity.certSha1),
                    expectsBinary = true
                ),
                product = ApiProduct.MAP_TILES,
                cancellation = cancellation
            )
            val httpStatus = response.httpStatus
            if (httpStatus in 200..299) {
                ProviderResponse(
                    success = true,
                    httpStatus = httpStatus,
                    safeDetail = "Map tile fetched.",
                    bytes = response.bodyBytes
                )
            } else {
                ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = safeErrorDetail(response.bodyText, key, sessionToken)
                )
            }
        } catch (blocked: ApiUsageBlockedException) {
            throw blocked
        } catch (cancelled: ProviderOperationCancelledException) {
            throw cancelled
        } catch (_: SocketTimeoutException) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network timeout.")
        } catch (_: Exception) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network or provider request failed.")
        }
    }

    private fun watchTileFailure(
        status: Map<String, Any?>,
        detail: String,
        errorCategory: Int,
        worldX: Int,
        worldY: Int,
        zoom: Int,
        httpStatus: Int? = null
    ): WatchTilePreparation = WatchTilePreparation(
        worldX, worldY, zoom, encoded = null, providerStatus = status,
        failure = operationFailure(status, detail, errorCategory, httpStatus)
    )

    private fun watchTileSuccess(
        worldX: Int, worldY: Int, zoom: Int, width: Int, height: Int,
        encoded: EncodedWatchTile, source: String, metrics: Map<String, Any>
    ): WatchTilePreparation {
        check(encoded.width == width && encoded.height == height)
        return WatchTilePreparation(worldX, worldY, zoom,
            encoded.copy(preparationMetrics = metrics), keyStore.getStatus(), source)
    }

    private fun sourceTilesForCrop(
        cropWorldX: Int,
        cropWorldY: Int,
        zoom: Int,
        worldSize: Int,
        watchTileWidth: Int,
        watchTileHeight: Int
    ): Set<Pair<Int, Int>> =
        sourceTileKeysForWatchCrop(
            cropWorldX,
            cropWorldY,
            zoom,
            worldSize,
            watchTileWidth,
            watchTileHeight
        )

    private fun geocodeAddress(
        key: String,
        identity: AndroidIdentity,
        address: String,
        language: String,
        region: String
    ): ProviderResponse {
        val query = buildList {
            add("address=${encoded(address)}")
            add("key=${encoded(key)}")
            if (language.isNotBlank()) {
                add("language=${encoded(language)}")
            }
            if (region.isNotBlank()) {
                add("region=${encoded(region.lowercase())}")
            }
        }.joinToString("&")
        return try {
            val response = executeProviderRequest(
                GoogleHttpRequest(
                    url = "$GEOCODING_BASE_URL/geocode/json?$query",
                    headers = androidHeaders(identity.packageName, identity.certSha1)
                ),
                product = ApiProduct.GEOCODING
            )
            val httpStatus = response.httpStatus
            if (httpStatus !in 200..299) {
                return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = safeErrorDetail(response.bodyText, key)
                )
            }

            val json = JSONObject(response.bodyText)
            val providerStatus = json.optString("status", "")
            if (providerStatus != "OK") {
                return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    providerStatus = providerStatus,
                    safeDetail = safeGeocodingDetail(json, providerStatus, key)
                )
            }

            val first = json.optJSONArray("results")?.optJSONObject(0)
                ?: return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    providerStatus = providerStatus,
                    safeDetail = "Geocoding returned no results."
                )
            val location = first
                .optJSONObject("geometry")
                ?.optJSONObject("location")
                ?: return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    providerStatus = providerStatus,
                    safeDetail = "Geocoding response did not include coordinates."
                )

            ProviderResponse(
                success = true,
                httpStatus = httpStatus,
                providerStatus = providerStatus,
                safeDetail = "Geocoding succeeded.",
                geocode = GeocodeResult(
                    latitude = location.getDouble("lat"),
                    longitude = location.getDouble("lng"),
                    formattedAddress = first.optString("formatted_address", address),
                    placeId = first.optString("place_id").takeIf { it.isNotBlank() }
                )
            )
        } catch (blocked: ApiUsageBlockedException) {
            throw blocked
        } catch (cancelled: ProviderOperationCancelledException) {
            throw cancelled
        } catch (_: SocketTimeoutException) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network timeout.")
        } catch (_: Exception) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network or provider request failed.")
        }
    }

    private fun autocompletePlaces(
        key: String,
        identity: AndroidIdentity,
        input: String,
        origin: LatLng?,
        sessionToken: String?,
        language: String,
        region: String
    ): ProviderResponse {
        val bodyJson = JSONObject()
            .put("input", input)
            .put("languageCode", language.ifBlank { DEFAULT_LANGUAGE })
            .put("regionCode", region.ifBlank { DEFAULT_REGION }.uppercase())
            .put("includeQueryPredictions", false)
        if (!sessionToken.isNullOrBlank()) {
            bodyJson.put("sessionToken", sessionToken)
        }
        if (origin != null) {
            bodyJson
                .put("origin", latLngJson(origin))
                .put(
                    "locationBias",
                    JSONObject().put(
                        "circle",
                        JSONObject()
                            .put("center", latLngJson(origin))
                            .put("radius", PLACES_AUTOCOMPLETE_LOCATION_BIAS_RADIUS_METERS)
                    )
                )
        }
        val body = bodyJson.toString().toByteArray(Charsets.UTF_8)

        return try {
            val response = executeProviderRequest(
                GoogleHttpRequest(
                    url = PLACES_AUTOCOMPLETE_URL,
                    method = "POST",
                    headers = androidHeaders(identity.packageName, identity.certSha1) +
                        mapOf(
                            "Content-Type" to "application/json; charset=utf-8",
                            "X-Goog-Api-Key" to key,
                            "X-Goog-FieldMask" to PLACES_AUTOCOMPLETE_FIELD_MASK
                        ),
                    body = body
                ),
                product = ApiProduct.AUTOCOMPLETE
            )
            val httpStatus = response.httpStatus
            if (httpStatus !in 200..299) {
                return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = safeErrorDetail(response.bodyText, key, sessionToken.orEmpty())
                )
            }

            val json = JSONObject(response.bodyText)
            val suggestionsJson = json.optJSONArray("suggestions") ?: JSONArray()
            val suggestions = mutableListOf<PlaceSuggestion>()
            for (index in 0 until suggestionsJson.length()) {
                val prediction = suggestionsJson
                    .optJSONObject(index)
                    ?.optJSONObject("placePrediction")
                    ?: continue
                val placeId = prediction.optString("placeId", "")
                if (placeId.isBlank()) {
                    continue
                }
                val text = prediction
                    .optJSONObject("text")
                    ?.optString("text", "")
                    .orEmpty()
                val structured = prediction.optJSONObject("structuredFormat")
                val primary = structured
                    ?.optJSONObject("mainText")
                    ?.optString("text", "")
                    .orEmpty()
                val secondary = structured
                    ?.optJSONObject("secondaryText")
                    ?.optString("text", "")
                    .orEmpty()
                suggestions.add(
                    PlaceSuggestion(
                        placeId = placeId,
                        primaryText = primary.ifBlank { text },
                        secondaryText = secondary,
                        fullText = text
                    )
                )
            }

            ProviderResponse(
                success = true,
                httpStatus = httpStatus,
                safeDetail = "Autocomplete succeeded.",
                suggestions = suggestions.take(MAX_PLACE_SUGGESTIONS)
            )
        } catch (blocked: ApiUsageBlockedException) {
            throw blocked
        } catch (cancelled: ProviderOperationCancelledException) {
            throw cancelled
        } catch (_: SocketTimeoutException) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network timeout.")
        } catch (_: Exception) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network or provider request failed.")
        }
    }

    private fun placeDetails(
        key: String,
        identity: AndroidIdentity,
        placeId: String,
        sessionToken: String?,
        language: String,
        region: String
    ): ProviderResponse {
        val query = buildList {
            if (language.isNotBlank()) {
                add("languageCode=${encoded(language)}")
            }
            if (region.isNotBlank()) {
                add("regionCode=${encoded(region.uppercase())}")
            }
            if (!sessionToken.isNullOrBlank()) {
                add("sessionToken=${encoded(sessionToken)}")
            }
        }.joinToString("&")
        val url = buildString {
            append(PLACES_DETAILS_BASE_URL)
            append("/")
            append(encoded(placeId))
            if (query.isNotBlank()) {
                append("?")
                append(query)
            }
        }
        return try {
            val response = executeProviderRequest(
                GoogleHttpRequest(
                    url = url,
                    headers = androidHeaders(identity.packageName, identity.certSha1) +
                        mapOf(
                            "X-Goog-Api-Key" to key,
                            "X-Goog-FieldMask" to PLACES_DETAILS_FIELD_MASK
                        )
                ),
                product = ApiProduct.PLACE_DETAILS
            )
            val httpStatus = response.httpStatus
            if (httpStatus !in 200..299) {
                return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = safeErrorDetail(response.bodyText, key, sessionToken.orEmpty())
                )
            }

            val json = JSONObject(response.bodyText)
            val location = json.optJSONObject("location")
                ?: return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = "Places Details response did not include coordinates."
                )
            val label = json
                .optJSONObject("displayName")
                ?.optString("text", "")
                .orEmpty()
            val formattedAddress = json.optString("formattedAddress", "")
            ProviderResponse(
                success = true,
                httpStatus = httpStatus,
                safeDetail = "Place resolved.",
                geocode = GeocodeResult(
                    latitude = location.getDouble("latitude"),
                    longitude = location.getDouble("longitude"),
                    formattedAddress = formattedAddress.ifBlank { label.ifBlank { placeId } },
                    placeId = json.optString("id", placeId).ifBlank { placeId },
                    label = label.ifBlank { formattedAddress.ifBlank { placeId } }
                )
            )
        } catch (blocked: ApiUsageBlockedException) {
            throw blocked
        } catch (cancelled: ProviderOperationCancelledException) {
            throw cancelled
        } catch (_: SocketTimeoutException) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network timeout.")
        } catch (_: Exception) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network or provider request failed.")
        }
    }

    private fun computeGoogleRoute(
        key: String,
        identity: AndroidIdentity,
        origin: LatLng,
        destination: LatLng,
        travelMode: String,
        language: String
    ): ProviderResponse {
        val body = JSONObject()
            .put("origin", waypoint(origin))
            .put("destination", waypoint(destination))
            .put("travelMode", googleTravelMode(travelMode))
            .put("computeAlternativeRoutes", false)
            .put("languageCode", language.ifBlank { DEFAULT_LANGUAGE })
            .put("units", "METRIC")
            .put("polylineQuality", "HIGH_QUALITY")
            .toString()
            .toByteArray(Charsets.UTF_8)

        return try {
            val response = executeProviderRequest(
                GoogleHttpRequest(
                    url = ROUTES_URL,
                    method = "POST",
                    headers = androidHeaders(identity.packageName, identity.certSha1) +
                        mapOf(
                            "Content-Type" to "application/json; charset=utf-8",
                            "X-Goog-Api-Key" to key,
                            "X-Goog-FieldMask" to ROUTES_FIELD_MASK
                        ),
                    body = body
                ),
                product = ApiProduct.ROUTES
            )
            val httpStatus = response.httpStatus
            if (httpStatus !in 200..299) {
                return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = safeErrorDetail(response.bodyText, key)
                )
            }

            val json = JSONObject(response.bodyText)
            val routeJson = json.optJSONArray("routes")?.optJSONObject(0)
                ?: return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = "Routes returned no route.",
                    noRoute = true
                )

            val route = normalizeRoute(routeJson, travelMode, origin)
                ?: return ProviderResponse(
                    success = false,
                    httpStatus = httpStatus,
                    safeDetail = "Routes response did not include usable geometry."
                )

            ProviderResponse(
                success = true,
                httpStatus = httpStatus,
                safeDetail = "Route computed.",
                route = route
            )
        } catch (blocked: ApiUsageBlockedException) {
            throw blocked
        } catch (cancelled: ProviderOperationCancelledException) {
            throw cancelled
        } catch (_: SocketTimeoutException) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network timeout.")
        } catch (_: Exception) {
            ProviderResponse(success = false, httpStatus = null, safeDetail = "Network or provider request failed.")
        }
    }

    private fun normalizeRoute(
        routeJson: JSONObject,
        travelMode: String,
        origin: LatLng
    ): NormalizedRoute? {
        val encodedPolyline = routeJson
            .optJSONObject("polyline")
            ?.optString("encodedPolyline", "")
            .orEmpty()
        if (encodedPolyline.isBlank()) {
            return null
        }

        val decoded = decodePolyline(encodedPolyline)
        val simplified = compactRoutePoints(decoded, origin, travelMode)
        if (simplified.size < 2) {
            return null
        }

        val steps = parseSteps(routeJson).let { parsed ->
            if (parsed.size <= MAX_ROUTE_STEPS) parsed else downsampleSteps(parsed, MAX_ROUTE_STEPS)
        }

        return NormalizedRoute(
            travelMode = travelMode,
            distanceMeters = routeJson.optInt("distanceMeters", 0),
            durationSeconds = parseDurationSeconds(routeJson.optString("duration", "0s")),
            encodedPolyline = encodedPolyline,
            routePoints = simplified.map { worldPoint(it) },
            fullRoutePoints = decoded.map { worldPoint(it) },
            steps = steps
        )
    }

    private fun parseSteps(routeJson: JSONObject): List<RouteStep> {
        val rawSteps = mutableListOf<RouteStepDraft>()
        val legs = routeJson.optJSONArray("legs") ?: JSONArray()
        for (legIndex in 0 until legs.length()) {
            val steps = legs.optJSONObject(legIndex)?.optJSONArray("steps") ?: continue
            for (stepIndex in 0 until steps.length()) {
                val step = steps.optJSONObject(stepIndex) ?: continue
                val start = step
                    .optJSONObject("startLocation")
                    ?.optJSONObject("latLng")
                    ?.let { LatLng(it.getDouble("latitude"), it.getDouble("longitude")) }
                    ?: continue
                rawSteps.add(
                    RouteStepDraft(
                        start = start,
                        instruction = truncateUtf8(
                            stripMarkup(
                                step.optJSONObject("navigationInstruction")
                                    ?.optString("instructions", "")
                                    .orEmpty()
                            ).ifBlank { "Continue" },
                            MAX_WATCH_TEXT_BYTES
                        ),
                        distanceMeters = step.optInt("distanceMeters", 0),
                        durationSeconds = parseDurationSeconds(step.optString("staticDuration", "0s"))
                    )
                )
            }
        }

        var remainingMeters = rawSteps.sumOf { it.distanceMeters }
        var remainingSeconds = rawSteps.sumOf { it.durationSeconds }
        return rawSteps.mapIndexed { index, step ->
            val point = worldPoint(step.start)
            RouteStep(
                index = index,
                startLatitude = step.start.latitude,
                startLongitude = step.start.longitude,
                startWorldX = point.worldX,
                startWorldY = point.worldY,
                instruction = step.instruction,
                distanceMeters = step.distanceMeters,
                durationSeconds = step.durationSeconds,
                remainingMeters = remainingMeters,
                remainingSeconds = remainingSeconds
            ).also {
                remainingMeters = (remainingMeters - step.distanceMeters).coerceAtLeast(0)
                remainingSeconds = (remainingSeconds - step.durationSeconds).coerceAtLeast(0)
            }
        }
    }

    private fun waypoint(coordinate: LatLng): JSONObject =
        JSONObject().put(
            "location",
            JSONObject().put(
                "latLng",
                latLngJson(coordinate)
            )
        )

    private fun latLngJson(coordinate: LatLng): JSONObject =
        JSONObject()
            .put("latitude", coordinate.latitude)
            .put("longitude", coordinate.longitude)

    private fun safeErrorDetail(responseText: String, vararg secrets: String): String {
        val message = try {
            JSONObject(responseText).optJSONObject("error")?.optString("message")
        } catch (_: Exception) {
            null
        }
        return redactSensitive(message ?: "Provider rejected the request.", *secrets)
            .take(MAX_DETAIL_LENGTH)
    }

    private fun safeGeocodingDetail(json: JSONObject, providerStatus: String, vararg secrets: String): String {
        val message = json.optString("error_message", "").ifBlank {
            "Geocoding returned $providerStatus."
        }
        return redactSensitive(message, *secrets).take(MAX_DETAIL_LENGTH)
    }

    private fun redactSensitive(value: String, vararg secrets: String): String {
        var redacted = value.replace(GOOGLE_API_KEY_PATTERN, "[redacted-google-key]")
        secrets.filter { it.isNotBlank() }.forEach { secret ->
            redacted = redacted.replace(secret, "[redacted]")
        }
        return redacted
    }

    private fun providerFailure(
        state: String,
        detail: String,
        httpStatus: Int?,
        identity: AndroidIdentity,
        errorCategory: Int
    ): Map<String, Any?> =
        operationFailure(
            status = keyStore.markValidationResult(
                state,
                detail,
                httpStatus,
                identity.packageName,
                identity.certSha1
            ),
            detail = detail,
            errorCategory = errorCategory,
            httpStatus = httpStatus
        )

    private fun operationFailure(
        status: Map<String, Any?>,
        detail: String,
        errorCategory: Int,
        httpStatus: Int? = null
    ): Map<String, Any?> =
        mapOf(
            "ok" to false,
            "providerStatus" to status,
            "detail" to detail,
            "errorCategory" to errorCategory,
            "httpStatus" to httpStatus
        ).filterValues { it != null }

    private fun geocodeFailure(response: ProviderResponse, identity: AndroidIdentity): Map<String, Any?> {
        val state = mapGeocodingState(response)
        val category = when {
            response.httpStatus == null -> ERROR_NETWORK
            response.providerStatus == "ZERO_RESULTS" -> ERROR_ROUTE_PROVIDER
            state == ApiKeyStore.STATE_QUOTA_OR_BILLING ||
                state == ApiKeyStore.STATE_PROVIDER_PERMISSION_DENIED ||
                state == ApiKeyStore.STATE_API_DISABLED ||
                state == ApiKeyStore.STATE_INVALID_KEY -> ERROR_INVALID_KEY
            else -> ERROR_ROUTE_PROVIDER
        }
        val providerStatus = if (category == ERROR_ROUTE_PROVIDER && response.providerStatus == "ZERO_RESULTS") {
            keyStore.getStatus()
        } else {
            keyStore.markValidationResult(
                state,
                response.safeDetail,
                response.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        return operationFailure(providerStatus, response.safeDetail, category, response.httpStatus)
    }

    private fun routeFailure(response: ProviderResponse, identity: AndroidIdentity): Map<String, Any?> {
        if (response.noRoute) {
            return operationFailure(
                status = keyStore.getStatus(),
                detail = response.safeDetail,
                errorCategory = ERROR_NO_ROUTE,
                httpStatus = response.httpStatus
            ) + mapOf("routePoints" to emptyList<Map<String, Any?>>())
        }

        val state = mapHttpStatusToState(response.httpStatus)
        val category = when {
            response.httpStatus == null -> ERROR_NETWORK
            state == ApiKeyStore.STATE_QUOTA_OR_BILLING ||
                state == ApiKeyStore.STATE_PROVIDER_PERMISSION_DENIED ||
                state == ApiKeyStore.STATE_API_DISABLED ||
                state == ApiKeyStore.STATE_INVALID_KEY -> ERROR_INVALID_KEY
            else -> ERROR_ROUTE_PROVIDER
        }
        val providerStatus = if (category == ERROR_ROUTE_PROVIDER) {
            keyStore.getStatus()
        } else {
            keyStore.markValidationResult(
                state,
                response.safeDetail,
                response.httpStatus,
                identity.packageName,
                identity.certSha1
            )
        }
        return operationFailure(providerStatus, response.safeDetail, category, response.httpStatus)
    }

    private fun mapHttpStatusToState(httpStatus: Int?): String =
        when (httpStatus) {
            null -> ApiKeyStore.STATE_NETWORK_UNAVAILABLE
            400 -> ApiKeyStore.STATE_API_DISABLED
            401, 403 -> ApiKeyStore.STATE_PROVIDER_PERMISSION_DENIED
            402, 429 -> ApiKeyStore.STATE_QUOTA_OR_BILLING
            else -> if (httpStatus >= 500) {
                ApiKeyStore.STATE_NETWORK_UNAVAILABLE
            } else {
                ApiKeyStore.STATE_INVALID_KEY
            }
        }

    private fun mapGeocodingState(response: ProviderResponse): String =
        when (response.providerStatus) {
            "ZERO_RESULTS" -> ApiKeyStore.STATE_VALID
            "OVER_DAILY_LIMIT", "OVER_QUERY_LIMIT" -> ApiKeyStore.STATE_QUOTA_OR_BILLING
            "REQUEST_DENIED" -> ApiKeyStore.STATE_PROVIDER_PERMISSION_DENIED
            "UNKNOWN_ERROR" -> ApiKeyStore.STATE_NETWORK_UNAVAILABLE
            "INVALID_REQUEST" -> ApiKeyStore.STATE_INVALID_KEY
            else -> mapHttpStatusToState(response.httpStatus)
        }

    private fun providerStateToCategory(state: String?): Int =
        when (state) {
            ApiKeyStore.STATE_NOT_CONFIGURED -> ERROR_MISSING_KEY
            ApiKeyStore.STATE_NETWORK_UNAVAILABLE -> ERROR_NETWORK
            ApiKeyStore.STATE_VALID -> 0
            else -> ERROR_INVALID_KEY
        }

    private fun isRestrictionRejection(response: ProviderResponse): Boolean =
        response.httpStatus in EXPECTED_ANDROID_RESTRICTION_STATUSES ||
            response.providerStatus == "REQUEST_DENIED"

    private fun tileCoordinate(latitude: Double, longitude: Double, zoom: Int): TileCoordinate {
        val safeZoom = zoom.coerceIn(0, 21)
        val scale = 1 shl safeZoom
        val clampedLat = latitude.coerceIn(MIN_WEB_MERCATOR_LAT, MAX_WEB_MERCATOR_LAT)
        val wrappedLng = ((longitude + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
        val latRad = Math.toRadians(clampedLat)
        val worldX = ((wrappedLng + 180.0) / 360.0) * scale * SOURCE_TILE_SIZE
        val mercator = (1.0 - ln(tan(latRad) + 1.0 / cos(latRad)) / PI) / 2.0
        val worldY = mercator * scale * SOURCE_TILE_SIZE
        val tileX = floor(worldX / SOURCE_TILE_SIZE).toInt().floorMod(scale)
        val tileY = floor(worldY / SOURCE_TILE_SIZE).toInt().coerceIn(0, scale - 1)
        return TileCoordinate(
            tileX = tileX,
            tileY = tileY,
            zoom = safeZoom,
            offsetX = (worldX - tileX * SOURCE_TILE_SIZE).coerceIn(0.0, SOURCE_TILE_SIZE - 1.0),
            offsetY = (worldY - tileY * SOURCE_TILE_SIZE).coerceIn(0.0, SOURCE_TILE_SIZE - 1.0)
        )
    }

    private fun scaledOffset(logicalOffset: Double, tileDimension: Int): Double =
        (logicalOffset * tileDimension / SOURCE_TILE_SIZE).coerceIn(0.0, (tileDimension - 1).toDouble())

    private fun scaledSourcePixel(logicalPixel: Int, bitmapDimension: Int): Int =
        providerPixelForLogicalPixel(logicalPixel, bitmapDimension)

    private fun worldPoint(coordinate: LatLng): RoutePoint {
        val scale = 1 shl ROUTE_WORLD_ZOOM
        val clampedLat = coordinate.latitude.coerceIn(MIN_WEB_MERCATOR_LAT, MAX_WEB_MERCATOR_LAT)
        val wrappedLng = ((coordinate.longitude + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
        val latRad = Math.toRadians(clampedLat)
        val worldX = ((wrappedLng + 180.0) / 360.0) * scale * SOURCE_TILE_SIZE
        val mercator = (1.0 - ln(tan(latRad) + 1.0 / cos(latRad)) / PI) / 2.0
        val worldY = mercator * scale * SOURCE_TILE_SIZE
        return RoutePoint(
            latitude = coordinate.latitude,
            longitude = coordinate.longitude,
            worldX = worldX.roundToInt(),
            worldY = worldY.roundToInt()
        )
    }

    private fun decodePolyline(encoded: String): List<LatLng> {
        val points = mutableListOf<LatLng>()
        var index = 0
        var latitude = 0
        var longitude = 0

        while (index < encoded.length) {
            val latResult = decodePolylineValue(encoded, index)
            index = latResult.nextIndex
            latitude += latResult.delta

            val lngResult = decodePolylineValue(encoded, index)
            index = lngResult.nextIndex
            longitude += lngResult.delta

            points.add(LatLng(latitude / 1E5, longitude / 1E5))
        }

        return points
    }

    private fun decodePolylineValue(encoded: String, startIndex: Int): PolylineValue {
        var result = 0
        var shift = 0
        var index = startIndex
        var byte: Int
        do {
            byte = encoded[index++].code - 63
            result = result or ((byte and 0x1f) shl shift)
            shift += 5
        } while (byte >= 0x20 && index < encoded.length)
        val delta = if ((result and 1) != 0) (result shr 1).inv() else result shr 1
        return PolylineValue(delta, index)
    }

    private fun compactRoutePoints(
        points: List<LatLng>,
        origin: LatLng,
        travelMode: String
    ): List<LatLng> {
        if (points.size <= 2) {
            return points
        }

        val simplified = douglasPeucker(points, ROUTE_UNIFORM_DP_TOLERANCE_M)
        if (simplified.size <= ROUTE_FEATHER_THRESHOLD) {
            return simplified
        }

        val feathered = buildFeatheredRoute(points, origin, travelMode)
        if (feathered != null && feathered.size >= 2) {
            return feathered
        }

        return downsamplePoints(simplified, MAX_ROUTE_POINTS)
    }

    private fun douglasPeucker(points: List<LatLng>, toleranceMeters: Double): List<LatLng> {
        if (points.size < 3) {
            return points
        }

        val keep = BooleanArray(points.size)
        keep[0] = true
        keep[points.lastIndex] = true
        val stack = mutableListOf(0 to points.lastIndex)
        while (stack.isNotEmpty()) {
            val (start, end) = stack.removeAt(stack.lastIndex)
            if (end - start < 2) {
                continue
            }
            var maxDistance = 0.0
            var maxIndex = -1
            for (index in start + 1 until end) {
                val distance = perpendicularDistanceMeters(points[index], points[start], points[end])
                if (distance > maxDistance) {
                    maxDistance = distance
                    maxIndex = index
                }
            }
            if (maxDistance > toleranceMeters && maxIndex > start) {
                keep[maxIndex] = true
                stack.add(start to maxIndex)
                stack.add(maxIndex to end)
            }
        }

        return points.filterIndexed { index, _ -> keep[index] }
    }

    private fun perpendicularDistanceMeters(point: LatLng, start: LatLng, end: LatLng): Double {
        val metersPerLatDegree = METERS_PER_LATITUDE_DEGREE
        val metersPerLngDegree = METERS_PER_LATITUDE_DEGREE * cos(Math.toRadians(start.latitude))
        val ax = start.longitude * metersPerLngDegree
        val ay = start.latitude * metersPerLatDegree
        val bx = end.longitude * metersPerLngDegree
        val by = end.latitude * metersPerLatDegree
        val px = point.longitude * metersPerLngDegree
        val py = point.latitude * metersPerLatDegree
        val dx = bx - ax
        val dy = by - ay
        val lengthSquared = dx * dx + dy * dy
        if (lengthSquared < 0.001) {
            val pointDx = px - ax
            val pointDy = py - ay
            return sqrt(pointDx * pointDx + pointDy * pointDy)
        }

        val projectedFraction = (((px - ax) * dx + (py - ay) * dy) / lengthSquared).coerceIn(0.0, 1.0)
        val projectedX = ax + projectedFraction * dx
        val projectedY = ay + projectedFraction * dy
        val offX = px - projectedX
        val offY = py - projectedY
        return sqrt(offX * offX + offY * offY)
    }

    private fun buildFeatheredRoute(
        points: List<LatLng>,
        origin: LatLng,
        travelMode: String
    ): List<LatLng>? {
        if (points.size < 3) {
            return points
        }

        val multiplier = routeDetailMultiplier(travelMode)
        val denseRadiusMeters = DENSE_BASE_RADIUS_M * multiplier
        val denseToleranceMeters = DENSE_BASE_DP_TOLERANCE_M * multiplier
        val destinationToleranceMeters = denseToleranceMeters / DESTINATION_DENSITY_MULTIPLIER
        val originIndex = nearestIndex(points, origin)
        val destinationIndex = points.lastIndex
        val originBounds = radialSliceIndices(points, originIndex, denseRadiusMeters)
        val destinationBounds = radialSliceIndices(points, destinationIndex, denseRadiusMeters)
        if (originBounds.second >= destinationBounds.first) {
            return null
        }

        val originRegion = buildRouteRegion(
            points.subList(originBounds.first, originBounds.second + 1),
            denseToleranceMeters,
            DENSE_ROUTE_POINT_BUDGET
        )
        val destinationRegion = buildRouteRegion(
            points.subList(destinationBounds.first, destinationBounds.second + 1),
            destinationToleranceMeters,
            DESTINATION_ROUTE_POINT_BUDGET
        )
        val middleBudget = (MAX_ROUTE_POINTS - originRegion.size - destinationRegion.size)
            .coerceAtMost(MIDDLE_ROUTE_POINT_BUDGET)
            .coerceAtLeast(MIN_MIDDLE_ROUTE_POINTS)
        val middleRegion = buildRouteRegion(
            points.subList(originBounds.second, destinationBounds.first + 1),
            MIDDLE_ROUTE_DP_TOLERANCE_M,
            middleBudget
        )

        val result = mutableListOf<LatLng>()
        result.addAll(originRegion)
        result.addAll(middleRegion.drop(1))
        result.addAll(destinationRegion.drop(1))
        return if (result.size > MAX_ROUTE_POINTS) {
            downsamplePoints(result, MAX_ROUTE_POINTS)
        } else {
            result
        }
    }

    private fun buildRouteRegion(
        points: List<LatLng>,
        toleranceMeters: Double,
        budget: Int
    ): List<LatLng> {
        if (points.size <= 1) {
            return points
        }
        val simplified = douglasPeucker(points, toleranceMeters)
        return downsamplePoints(simplified, budget)
    }

    private fun nearestIndex(points: List<LatLng>, target: LatLng): Int {
        var bestIndex = 0
        var bestDistanceSquared = Double.POSITIVE_INFINITY
        points.forEachIndexed { index, point ->
            val latitudeDelta = point.latitude - target.latitude
            val longitudeDelta = point.longitude - target.longitude
            val distanceSquared = latitudeDelta * latitudeDelta + longitudeDelta * longitudeDelta
            if (distanceSquared < bestDistanceSquared) {
                bestDistanceSquared = distanceSquared
                bestIndex = index
            }
        }
        return bestIndex
    }

    private fun radialSliceIndices(
        points: List<LatLng>,
        anchorIndex: Int,
        radiusMeters: Double
    ): Pair<Int, Int> {
        var startIndex = anchorIndex.coerceIn(0, points.lastIndex)
        var endIndex = startIndex
        var distanceMeters = 0.0
        for (index in startIndex downTo 1) {
            distanceMeters += haversineMeters(points[index], points[index - 1])
            if (distanceMeters >= radiusMeters) {
                break
            }
            startIndex = index - 1
        }

        distanceMeters = 0.0
        for (index in endIndex until points.lastIndex) {
            distanceMeters += haversineMeters(points[index], points[index + 1])
            if (distanceMeters >= radiusMeters) {
                break
            }
            endIndex = index + 1
        }
        return startIndex to endIndex
    }

    private fun haversineMeters(start: LatLng, end: LatLng): Double {
        val startLatRad = Math.toRadians(start.latitude)
        val endLatRad = Math.toRadians(end.latitude)
        val latDelta = Math.toRadians(end.latitude - start.latitude)
        val lngDelta = Math.toRadians(end.longitude - start.longitude)
        val value = sin(latDelta / 2) * sin(latDelta / 2) +
            cos(startLatRad) * cos(endLatRad) * sin(lngDelta / 2) * sin(lngDelta / 2)
        val clamped = value.coerceIn(0.0, 1.0)
        return EARTH_RADIUS_M * 2 * atan2(sqrt(clamped), sqrt(1 - clamped))
    }

    private fun routeDetailMultiplier(travelMode: String): Double =
        when (normalizedTravelMode(travelMode)) {
            TRAVEL_MODE_WALK -> ROUTE_DETAIL_WALK_MULTIPLIER
            TRAVEL_MODE_BIKE -> ROUTE_DETAIL_BIKE_MULTIPLIER
            TRAVEL_MODE_DRIVE -> ROUTE_DETAIL_DRIVE_MULTIPLIER
            else -> ROUTE_DETAIL_BIKE_MULTIPLIER
        }

    private fun downsamplePoints(points: List<LatLng>, maxCount: Int): List<LatLng> {
        if (points.size <= maxCount) {
            return points
        }
        return (0 until maxCount).map { index ->
            val sourceIndex = ((index.toDouble() * (points.lastIndex)) / (maxCount - 1)).roundToInt()
            points[sourceIndex]
        }
    }

    private fun downsampleSteps(steps: List<RouteStep>, maxCount: Int): List<RouteStep> {
        if (steps.size <= maxCount) {
            return steps
        }
        return (0 until maxCount).map { index ->
            val sourceIndex = ((index.toDouble() * (steps.lastIndex)) / (maxCount - 1)).roundToInt()
            steps[sourceIndex].copy(index = index)
        }
    }

    private fun parseDurationSeconds(value: String): Int =
        value.removeSuffix("s").toDoubleOrNull()?.roundToInt() ?: 0

    private fun stripMarkup(value: String): String =
        value.replace(Regex("<[^>]*>"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()

    private fun truncateUtf8(value: String, maxBytes: Int): String {
        val builder = StringBuilder()
        var usedBytes = 0
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            val chunk = String(Character.toChars(codePoint))
            val byteCount = chunk.toByteArray(Charsets.UTF_8).size
            if (usedBytes + byteCount > maxBytes) {
                break
            }
            builder.append(chunk)
            usedBytes += byteCount
            index += Character.charCount(codePoint)
        }
        return builder.toString()
    }

    private fun normalizedTravelMode(value: String): String =
        when (value.lowercase()) {
            TRAVEL_MODE_WALK -> TRAVEL_MODE_WALK
            TRAVEL_MODE_BIKE -> TRAVEL_MODE_BIKE
            else -> TRAVEL_MODE_DRIVE
        }

    private fun googleTravelMode(value: String): String =
        when (normalizedTravelMode(value)) {
            TRAVEL_MODE_WALK -> "WALK"
            TRAVEL_MODE_BIKE -> "BICYCLE"
            else -> "DRIVE"
        }

    private fun routeModeWarning(value: String): String? =
        when (normalizedTravelMode(value)) {
            TRAVEL_MODE_WALK, TRAVEL_MODE_BIKE ->
                "Walk and bike routes may miss safe pedestrian or bicycling path detail."
            else -> null
        }

    private fun Int.floorMod(modulus: Int): Int = ((this % modulus) + modulus) % modulus

    private fun encoded(value: String): String = URLEncoder.encode(value, Charsets.UTF_8.name())

    private fun androidHeaders(packageName: String, certSha1: String): Map<String, String> =
        mapOf(
            "X-Android-Package" to packageName,
            "X-Android-Cert" to certSha1
        )

    private data class LatLng(val latitude: Double, val longitude: Double)
    private data class GeocodeResult(
        val latitude: Double,
        val longitude: Double,
        val formattedAddress: String,
        val placeId: String?,
        val label: String = formattedAddress
    )

    private data class PlaceSuggestion(
        val placeId: String,
        val primaryText: String,
        val secondaryText: String,
        val fullText: String
    ) {
        fun asMap(): Map<String, Any?> =
            mapOf(
                "placeId" to placeId,
                "primaryText" to primaryText,
                "secondaryText" to secondaryText,
                "fullText" to fullText
            )
    }

    private data class NormalizedRoute(
        val travelMode: String,
        val distanceMeters: Int,
        val durationSeconds: Int,
        val encodedPolyline: String,
        val routePoints: List<RoutePoint>,
        val fullRoutePoints: List<RoutePoint>,
        val steps: List<RouteStep>
    )

    private data class RoutePoint(
        val latitude: Double,
        val longitude: Double,
        val worldX: Int,
        val worldY: Int
    ) {
        fun asMap(): Map<String, Any?> =
            mapOf(
                "latitude" to latitude,
                "longitude" to longitude,
                "worldX" to worldX,
                "worldY" to worldY
            )
    }

    private data class RouteStepDraft(
        val start: LatLng,
        val instruction: String,
        val distanceMeters: Int,
        val durationSeconds: Int
    )

    private data class RouteStep(
        val index: Int,
        val startLatitude: Double,
        val startLongitude: Double,
        val startWorldX: Int,
        val startWorldY: Int,
        val instruction: String,
        val distanceMeters: Int,
        val durationSeconds: Int,
        val remainingMeters: Int,
        val remainingSeconds: Int
    ) {
        fun asMap(): Map<String, Any?> =
            mapOf(
                "index" to index,
                "startLatitude" to startLatitude,
                "startLongitude" to startLongitude,
                "startWorldX" to startWorldX,
                "startWorldY" to startWorldY,
                "instruction" to instruction,
                "distanceMeters" to distanceMeters,
                "durationSeconds" to durationSeconds,
                "remainingMeters" to remainingMeters,
                "remainingSeconds" to remainingSeconds
            )
    }

    data class MapTileSettings(
        val mapSource: String = SOURCE_ROADMAP,
        val watchTileWidth: Int = WATCH_TILE_WIDTH,
        val watchTileHeight: Int = WATCH_TILE_HEIGHT
    ) {
        val cacheKey: String
            get() = "$mapSource:${watchTileWidth}x$watchTileHeight"

        val googleMapType: String
            get() = when (mapSource) {
                SOURCE_SATELLITE, SOURCE_HYBRID -> "satellite"
                SOURCE_TERRAIN -> "terrain"
                else -> "roadmap"
            }

        val googleLayerTypes: List<String>
            get() = when (mapSource) {
                SOURCE_HYBRID, SOURCE_TERRAIN -> listOf("layerRoadmap")
                else -> emptyList()
            }

        val googleOverlay: Boolean?
            get() = if (mapSource == SOURCE_HYBRID) false else null

        val googleScale: String
            get() = "scaleFactor1x"

        val highDpi: Boolean
            get() = false

        val googleImageFormat: String?
            get() = null

        fun asMap(): Map<String, Any?> =
            mapOf(
                "mapSource" to mapSource,
                "watchTileWidth" to watchTileWidth,
                "watchTileHeight" to watchTileHeight,
                "watchTileSize" to "${watchTileWidth}x${watchTileHeight}"
            )

        companion object {
            const val SOURCE_ROADMAP = "roadmap"
            const val SOURCE_SATELLITE = "satellite"
            const val SOURCE_HYBRID = "hybrid"
            const val SOURCE_TERRAIN = "terrain"

            fun fromMap(raw: Map<*, *>?): MapTileSettings =
                MapTileSettings(
                    mapSource = normalize(
                        value = raw?.get("mapSource") ?: raw?.get("map_source"),
                        allowed = setOf(SOURCE_ROADMAP, SOURCE_SATELLITE, SOURCE_HYBRID, SOURCE_TERRAIN),
                        fallback = SOURCE_ROADMAP
                    ),
                    watchTileWidth = normalizeTileSize(raw).first,
                    watchTileHeight = normalizeTileSize(raw).second
                )

            private fun normalize(value: Any?, allowed: Set<String>, fallback: String): String {
                val normalized = value?.toString()?.trim()?.lowercase().orEmpty()
                return if (normalized in allowed) normalized else fallback
            }

            private fun normalizeTileSize(raw: Map<*, *>?): Pair<Int, Int> {
                val sizeText = raw?.get("watchTileSize") ?: raw?.get("watch_tile_size")
                if (sizeText != null) {
                    val parts = sizeText.toString().lowercase().split("x")
                    if (parts.size == 2) {
                        val width = parts[0].trim().toIntOrNull()
                        val height = parts[1].trim().toIntOrNull()
                        when {
                            width == 72 && height == 84 -> return 72 to 84
                            width == 108 && height == 126 -> return 108 to 126
                            width == WATCH_TILE_WIDTH && height == WATCH_TILE_HEIGHT ->
                                return WATCH_TILE_WIDTH to WATCH_TILE_HEIGHT
                        }
                    }
                }
                val widthValue = raw?.get("watchTileWidth") ?: raw?.get("watch_tile_width")
                val heightValue = raw?.get("watchTileHeight") ?: raw?.get("watch_tile_height")
                val width = when (widthValue) {
                    is Number -> widthValue.toInt()
                    else -> widthValue?.toString()?.trim()?.toIntOrNull()
                }
                val height = when (heightValue) {
                    is Number -> heightValue.toInt()
                    else -> heightValue?.toString()?.trim()?.toIntOrNull()
                }
                return when {
                    width == 72 && height == 84 -> 72 to 84
                    width == 108 && height == 126 -> 108 to 126
                    else -> WATCH_TILE_WIDTH to WATCH_TILE_HEIGHT
                }
            }
        }
    }

    private data class ProviderResponse(
        val success: Boolean,
        val httpStatus: Int?,
        val safeDetail: String,
        val providerStatus: String? = null,
        val session: TileSession? = null,
        val bytes: ByteArray? = null,
        val geocode: GeocodeResult? = null,
        val suggestions: List<PlaceSuggestion> = emptyList(),
        val route: NormalizedRoute? = null,
        val noRoute: Boolean = false
    )

    private data class TileCoordinate(
        val tileX: Int,
        val tileY: Int,
        val zoom: Int,
        val offsetX: Double,
        val offsetY: Double
    )

    private data class TileSession(
        val sessionToken: String,
        val tileWidth: Int,
        val tileHeight: Int,
        val settingsKey: String
    )
    private data class PolylineValue(val delta: Int, val nextIndex: Int)

    companion object {
        private const val GEOCODING_BASE_URL = "https://maps.googleapis.com/maps/api"
        private const val MAP_TILES_BASE_URL = "https://tile.googleapis.com/v1"
        private const val PLACES_AUTOCOMPLETE_URL = "https://places.googleapis.com/v1/places:autocomplete"
        private const val PLACES_DETAILS_BASE_URL = "https://places.googleapis.com/v1/places"
        private const val PLACES_AUTOCOMPLETE_FIELD_MASK =
            "suggestions.placePrediction.placeId,suggestions.placePrediction.text.text," +
                "suggestions.placePrediction.structuredFormat.mainText.text," +
                "suggestions.placePrediction.structuredFormat.secondaryText.text"
        private const val PLACES_DETAILS_FIELD_MASK = "id,displayName,formattedAddress,location"
        private const val ROUTES_URL = "https://routes.googleapis.com/directions/v2:computeRoutes"
        private const val ROUTES_FIELD_MASK =
            "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline," +
                "routes.legs.steps.startLocation,routes.legs.steps.distanceMeters," +
                "routes.legs.steps.staticDuration,routes.legs.steps.navigationInstruction"
        private const val DEFAULT_LANGUAGE = "en-US"
        private const val DEFAULT_REGION = "US"
        private const val VALIDATION_ADDRESS = "1600 Amphitheatre Parkway, Mountain View, CA"
        private const val VALIDATION_PLACE_ID = "ChIJj61dQgK6j4AR4GeTYWZsKWw"
        private val VALIDATION_ROUTE_ORIGIN = LatLng(37.419734, -122.0827784)
        private val VALIDATION_ROUTE_DESTINATION = LatLng(37.417670, -122.079595)
        private const val MAX_DETAIL_LENGTH = 160
        private const val MAX_PLACE_SUGGESTIONS = 5
        private const val PLACES_AUTOCOMPLETE_LOCATION_BIAS_RADIUS_METERS = 10_000.0
        private const val MAX_ROUTE_POINTS = 128
        private const val ROUTE_FEATHER_THRESHOLD = 120
        private const val ROUTE_UNIFORM_DP_TOLERANCE_M = 8.0
        private const val DENSE_BASE_RADIUS_M = 2414.0
        private const val DENSE_BASE_DP_TOLERANCE_M = 3.0
        private const val DENSE_ROUTE_POINT_BUDGET = 48
        private const val DESTINATION_ROUTE_POINT_BUDGET = 32
        private const val DESTINATION_DENSITY_MULTIPLIER = 0.75
        private const val MIDDLE_ROUTE_DP_TOLERANCE_M = 50.0
        private const val MIDDLE_ROUTE_POINT_BUDGET = 40
        private const val MIN_MIDDLE_ROUTE_POINTS = 4
        private const val ROUTE_DETAIL_WALK_MULTIPLIER = 0.4
        private const val ROUTE_DETAIL_BIKE_MULTIPLIER = 1.0
        private const val ROUTE_DETAIL_DRIVE_MULTIPLIER = 3.0
        private const val METERS_PER_LATITUDE_DEGREE = 111_320.0
        private const val EARTH_RADIUS_M = 6_378_137.0
        private const val MAX_ROUTE_STEPS = 255
        private const val MAX_WATCH_TEXT_BYTES = 47
        private const val WATCH_TILE_WIDTH = 54
        private const val WATCH_TILE_HEIGHT = 63
        private const val MAX_SOURCE_TILE_CACHE_ENTRIES = 128
        private const val MAX_WATCH_TILE_CACHE_ENTRIES = 96
        private const val SOURCE_TILE_SIZE_INT = 256
        private const val SOURCE_TILE_SIZE = 256.0
        private const val MAX_WATCH_TILE_ZOOM = 21
        private const val ROUTE_WORLD_ZOOM = 16
        private const val MIN_WEB_MERCATOR_LAT = -85.05112878
        private const val MAX_WEB_MERCATOR_LAT = 85.05112878
        private const val TRAVEL_MODE_DRIVE = "drive"
        private const val TRAVEL_MODE_WALK = "walk"
        private const val TRAVEL_MODE_BIKE = "bike"
        private const val ERROR_MISSING_KEY = 1
        private const val ERROR_INVALID_KEY = 2
        private const val ERROR_NETWORK = 4
        private const val ERROR_TILE_PROVIDER = 5
        private const val ERROR_ROUTE_PROVIDER = 6
        private const val ERROR_NO_ROUTE = 7
        private const val ERROR_DESTINATION_NOT_CONFIGURED = 8
        private val EXPECTED_ANDROID_RESTRICTION_STATUSES = setOf(401, 403)
        private val GOOGLE_API_KEY_PATTERN = Regex("AIza[0-9A-Za-z_-]+")

        internal fun sourceTileKeysForWatchCrop(
            cropWorldX: Int,
            cropWorldY: Int,
            zoom: Int,
            worldSize: Int = (1 shl zoom.coerceIn(0, MAX_WATCH_TILE_ZOOM)) * SOURCE_TILE_SIZE_INT,
            watchTileWidth: Int = WATCH_TILE_WIDTH,
            watchTileHeight: Int = WATCH_TILE_HEIGHT
        ): Set<Pair<Int, Int>> {
            val safeZoom = zoom.coerceIn(0, MAX_WATCH_TILE_ZOOM)
            val safeWorldSize = worldSize.coerceAtLeast(SOURCE_TILE_SIZE_INT)
            val scale = 1 shl safeZoom
            fun wrapped(value: Int, modulus: Int): Int = ((value % modulus) + modulus) % modulus
            val xTiles = setOf(
                wrapped(cropWorldX, safeWorldSize) / SOURCE_TILE_SIZE_INT,
                wrapped(cropWorldX + watchTileWidth - 1, safeWorldSize) / SOURCE_TILE_SIZE_INT
            )
            val yTiles = setOf(
                cropWorldY.coerceIn(0, safeWorldSize - 1) / SOURCE_TILE_SIZE_INT,
                (cropWorldY + watchTileHeight - 1).coerceIn(0, safeWorldSize - 1) / SOURCE_TILE_SIZE_INT
            )
            return xTiles.flatMap { tileX ->
                yTiles.map { tileY -> wrapped(tileX, scale) to tileY.coerceIn(0, scale - 1) }
            }.toSet()
        }

        internal fun providerPixelForLogicalPixel(logicalPixel: Int, bitmapDimension: Int): Int =
            ((logicalPixel.toDouble() * bitmapDimension) / SOURCE_TILE_SIZE)
                .toInt()
                .coerceIn(0, bitmapDimension - 1)

        private fun <K, V> boundedCache(maxEntries: Int): LinkedHashMap<K, V> =
            object : LinkedHashMap<K, V>(16, 0.75f, true) {
                override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, V>?): Boolean =
                    size > maxEntries
            }
    }
}
