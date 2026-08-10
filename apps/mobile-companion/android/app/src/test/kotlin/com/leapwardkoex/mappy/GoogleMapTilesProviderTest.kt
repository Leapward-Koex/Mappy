package com.leapwardkoex.mappy

import org.json.JSONArray
import org.json.JSONObject
import kotlin.concurrent.thread
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class GoogleMapTilesProviderTest {
    @Test
    fun validateProviderSetupAttachesAndroidHeadersAndChecksWrongPackages() {
        val http = FakeGoogleHttpClient()
        val store = FakeCredentialStore()
        val provider = GoogleMapTilesProvider(store, FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        val status = provider.validateProviderSetup()

        assertEquals(ApiKeyStore.STATE_VALID, status["validationState"])
        assertEquals(10, http.requests.size)
        http.requests.forEach { request ->
            assertEquals(PACKAGE_NAME, request.headers["X-Android-Package"]?.removeSuffix(".wrong"))
            assertEquals(CERT_SHA1, request.headers["X-Android-Cert"])
        }
        assertTrue(http.requests.any { it.url.contains("createSession") && it.headers["X-Android-Package"] == "$PACKAGE_NAME.wrong" })
        assertTrue(http.requests.any { it.url.contains("geocode/json") && it.headers["X-Android-Package"] == "$PACKAGE_NAME.wrong" })
        assertTrue(http.requests.any { it.url.contains("places:autocomplete") && it.headers["X-Android-Package"] == "$PACKAGE_NAME.wrong" })
        assertTrue(http.requests.any { it.url.contains("places/") && it.headers["X-Android-Package"] == "$PACKAGE_NAME.wrong" })
        assertTrue(http.requests.any { it.url.contains("computeRoutes") && it.headers["X-Android-Package"] == "$PACKAGE_NAME.wrong" })
        assertTrue(http.requests.any { it.headers["X-Goog-FieldMask"]?.contains("suggestions.placePrediction.placeId") == true })
        assertTrue(http.requests.any { it.headers["X-Goog-FieldMask"]?.contains("formattedAddress") == true })
        assertTrue(http.requests.any { it.headers["X-Goog-FieldMask"]?.contains("routes.polyline.encodedPolyline") == true })
        val sessionBody = JSONObject(
            http.requests.first { it.url.contains("createSession") && it.headers["X-Android-Package"] == PACKAGE_NAME }
                .body!!.toString(Charsets.UTF_8)
        )
        assertEquals("roadmap", sessionBody.getString("mapType"))
        assertEquals("scaleFactor1x", sessionBody.getString("scale"))
        assertEquals(false, sessionBody.getBoolean("highDpi"))
        assertEquals(false, sessionBody.has("imageFormat"))
    }

    @Test
    fun androidIdentitySha1FormatterReturnsFortyUppercaseHexCharacters() {
        val sha1 = RuntimeAndroidIdentityProvider.sha1Hex(ByteArray(32) { it.toByte() })

        assertEquals(40, sha1.length)
        assertTrue(Regex("^[0-9A-F]{40}$").matches(sha1))
        assertTrue(!sha1.contains(":"))
    }

    @Test
    fun developmentKeyModeSkipsWrongPackageChecksAfterSuccessfulProviderCalls() {
        val http = FakeGoogleHttpClient()
        val store = FakeCredentialStore()
        val provider = GoogleMapTilesProvider(
            keyStore = store,
            identityProvider = FakeIdentityProvider(),
            httpClient = http,
            binaryStringEncoder = FakeBinaryStringEncoder(),
            allowUnrestrictedDevelopmentKey = { true }
        )

        val status = provider.validateProviderSetup()

        assertEquals(ApiKeyStore.STATE_VALID, status["validationState"])
        assertEquals(5, http.requests.size)
        assertTrue(http.requests.none { it.headers["X-Android-Package"] == "$PACKAGE_NAME.wrong" })
        assertTrue(http.requests.any { it.url.contains("createSession") })
        assertTrue(http.requests.any { it.url.contains("geocode/json") })
        assertTrue(http.requests.any { it.url.contains("places:autocomplete") })
        assertTrue(http.requests.any { it.url.contains("places/") })
        assertTrue(http.requests.any { it.url.contains("computeRoutes") })
    }

    @Test
    fun autocompleteAndResolvePlaceReturnNormalizedDestinationData() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        val autocomplete = provider.autocompleteDestination(
            input = "Googleplex",
            originLatitude = 37.42228,
            originLongitude = -122.08434,
            sessionToken = "session-token",
            language = "en-US",
            region = "US"
        )
        val suggestions = autocomplete["suggestions"] as? List<*>
        assertEquals(true, autocomplete["ok"])
        assertNotNull(suggestions)
        assertEquals("test-place-id", (suggestions.single() as Map<*, *>)["placeId"])

        val details = provider.resolvePlace(
            placeId = "test-place-id",
            sessionToken = "session-token",
            language = "en-US",
            region = "US"
        )

        assertEquals(true, details["ok"])
        assertEquals("Googleplex", details["label"])
        assertEquals(37.4222804, details["latitude"])
        assertEquals(-122.0843428, details["longitude"])
        assertEquals("google_places", details["provider"])
    }

    @Test
    fun geocodeDestinationValidatesFirstAndReturnsNormalizedCoordinates() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        val result = provider.geocodeDestination("1600 Amphitheatre Parkway", "en-US", "US")

        assertEquals(true, result["ok"])
        assertEquals(37.4222804, result["latitude"])
        assertEquals(-122.0843428, result["longitude"])
        assertEquals("google_geocoding", result["provider"])
        assertTrue(http.requests.take(6).any { it.headers["X-Android-Package"] == "$PACKAGE_NAME.wrong" })
        assertTrue(http.requests.last().url.contains("geocode/json"))
    }

    @Test
    fun computeRouteValidatesFirstAndReturnsNormalizedRoute() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        val result = provider.computeRoute(
            originLatitude = 38.5,
            originLongitude = -120.2,
            destinationAddress = null,
            destinationLatitude = 43.252,
            destinationLongitude = -126.453,
            travelMode = "drive",
            language = "en-US",
            region = "US"
        )

        assertEquals(true, result["ok"])
        assertEquals(1200, result["distanceMeters"])
        assertEquals(420, result["durationSeconds"])
        val routePoints = result["routePoints"] as? List<*>
        val steps = result["steps"] as? List<*>
        assertNotNull(routePoints)
        assertNotNull(steps)
        assertTrue(routePoints.size in 2..128)
        assertEquals(1, steps.size)
        assertTrue(http.requests.last().url.contains("computeRoutes"))
    }

    @Test
    fun sourceTileKeysCoverWatchCropBoundariesAndXWrap() {
        val worldSize = 4 * 256

        assertEquals(setOf(0 to 0), GoogleMapTilesProvider.sourceTileKeysForWatchCrop(10, 20, 2, worldSize))
        assertEquals(setOf(0 to 0, 1 to 0), GoogleMapTilesProvider.sourceTileKeysForWatchCrop(250, 20, 2, worldSize))
        assertEquals(setOf(0 to 0, 0 to 1), GoogleMapTilesProvider.sourceTileKeysForWatchCrop(10, 250, 2, worldSize))
        assertEquals(
            setOf(0 to 0, 1 to 0, 0 to 1, 1 to 1),
            GoogleMapTilesProvider.sourceTileKeysForWatchCrop(250, 250, 2, worldSize)
        )
        assertEquals(setOf(3 to 0, 0 to 0), GoogleMapTilesProvider.sourceTileKeysForWatchCrop(1000, 20, 2, worldSize))
        assertEquals(setOf(0 to 3), GoogleMapTilesProvider.sourceTileKeysForWatchCrop(10, 1020, 2, worldSize))
    }

    @Test
    fun watchTileCropsBoundaryFixturesAndRleRoundTripsLosslessly() {
        assertWatchTileCrop(worldX = 10, worldY = 20, zoom = 2, tileDimension = 256)
        assertWatchTileCrop(worldX = 250, worldY = 20, zoom = 2, tileDimension = 256)
        assertWatchTileCrop(worldX = 10, worldY = 250, zoom = 2, tileDimension = 256)
        assertWatchTileCrop(worldX = 250, worldY = 250, zoom = 2, tileDimension = 256)
        assertWatchTileCrop(worldX = 250, worldY = 250, zoom = 2, tileDimension = 512)
        assertWatchTileCrop(worldX = 250, worldY = 250, zoom = 2, tileDimension = 1024)
    }

    @Test
    fun highDpiSourceTileDimensionsMapToSameLogicalCoverage() {
        assertEquals(0, GoogleMapTilesProvider.providerPixelForLogicalPixel(0, 256))
        assertEquals(255, GoogleMapTilesProvider.providerPixelForLogicalPixel(255, 256))
        assertEquals(0, GoogleMapTilesProvider.providerPixelForLogicalPixel(0, 512))
        assertEquals(510, GoogleMapTilesProvider.providerPixelForLogicalPixel(255, 512))
        assertEquals(0, GoogleMapTilesProvider.providerPixelForLogicalPixel(0, 1024))
        assertEquals(1020, GoogleMapTilesProvider.providerPixelForLogicalPixel(255, 1024))
    }

    @Test
    fun fixedTileSettingsUseCompactAutomaticSessionParameters() {
        val session = sessionBodyForSettings(GoogleMapTilesProvider.MapTileSettings())

        assertEquals("scaleFactor1x", session.getString("scale"))
        assertEquals(false, session.getBoolean("highDpi"))
        assertEquals(false, session.has("imageFormat"))
    }

    @Test
    fun longDenseRouteIsCompactedAndStepIndexesAreCapped() {
        val http = FakeGoogleHttpClient(routeBody = longRouteBody(pointCount = 240, stepCount = 300))
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        val result = provider.computeRoute(
            originLatitude = 37.0,
            originLongitude = -122.0,
            destinationAddress = null,
            destinationLatitude = 37.08,
            destinationLongitude = -121.92,
            travelMode = "drive",
            language = "en-US",
            region = "US"
        )

        val routePoints = result["routePoints"] as? List<*>
        val fullRoutePoints = result["fullRoutePoints"] as? List<*>
        val steps = result["steps"] as? List<*>
        assertEquals(true, result["ok"])
        assertNotNull(routePoints)
        assertNotNull(fullRoutePoints)
        assertNotNull(steps)
        assertTrue(routePoints.size in 65..128)
        assertEquals(240, fullRoutePoints.size)
        assertEquals(255, steps.size)
        assertEquals(0, (steps.first() as Map<*, *>)["index"])
        assertEquals(254, (steps.last() as Map<*, *>)["index"])
        assertTrue(((steps.first() as Map<*, *>)["instruction"] as String).toByteArray(Charsets.UTF_8).size <= 47)
    }

    @Test
    fun routeSimplificationPreservesCriticalBends() {
        val routePoints = buildList {
            repeat(140) { index ->
                val latitude = 37.0 + index * 0.0001
                val longitude = if (index == 70) -121.985 else -122.0
                add(latitude to longitude)
            }
        }
        val http = FakeGoogleHttpClient(routeBody = routeBody(routePoints, stepCount = 1))
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        val result = provider.computeRoute(
            originLatitude = 37.0,
            originLongitude = -122.0,
            destinationAddress = null,
            destinationLatitude = 37.014,
            destinationLongitude = -122.0,
            travelMode = "drive",
            language = "en-US",
            region = "US"
        )

        val simplified = result["routePoints"] as? List<*>
        assertEquals(true, result["ok"])
        assertNotNull(simplified)
        assertTrue(simplified.size < routePoints.size)
        assertTrue(
            simplified.any {
                ((it as Map<*, *>)["longitude"] as Double) > -121.99
            }
        )
    }

    @Test
    fun clearProviderSessionsForcesNewMapTilesSession() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        provider.validateProviderSetup()
        provider.previewTile(37.4222804, -122.0843428, 16)
        val sessionsBeforeClear = http.requests.count { it.url.contains("createSession") }

        provider.clearProviderSessions()
        provider.previewTile(37.4222804, -122.0843428, 16)
        val sessionsAfterClear = http.requests.count { it.url.contains("createSession") }

        assertEquals(2, sessionsBeforeClear)
        assertEquals(4, sessionsAfterClear)
    }

    @Test
    fun clearProviderValidationCacheResetsValidationAndForcesSessionValidation() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        provider.validateProviderSetup()
        val sessionsBeforeClear = http.requests.count { it.url.contains("createSession") }
        val status = provider.clearProviderValidationCache()
        provider.previewTile(37.4222804, -122.0843428, 16)
        val sessionsAfterPreview = http.requests.count { it.url.contains("createSession") }

        assertEquals(ApiKeyStore.STATE_NOT_VALIDATED, status["validationState"])
        assertEquals(2, sessionsBeforeClear)
        assertEquals(4, sessionsAfterPreview)
    }

    @Test
    fun providerTileFailuresExposeHttpStatusForDiagnostics() {
        val http = FakeGoogleHttpClient(mapTileHttpStatus = 503)
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        provider.validateProviderSetup()
        val result = provider.previewTile(37.4222804, -122.0843428, 16)
        val status = result["providerStatus"] as Map<*, *>

        assertEquals(false, result["ok"])
        assertEquals(503, result["httpStatus"])
        assertEquals(503, status["validationHttpStatus"])
        assertEquals(ApiKeyStore.STATE_NETWORK_UNAVAILABLE, status["validationState"])
    }

    @Test
    fun duplicateWatchTileRequestsShareFirstRender() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(
            keyStore = FakeCredentialStore(),
            identityProvider = FakeIdentityProvider(),
            httpClient = http,
            binaryStringEncoder = FakeBinaryStringEncoder(),
            sourceTileDecoder = FixtureSourceTileDecoder(256)
        )
        provider.setMapTileSettings(GoogleMapTilesProvider.MapTileSettings())
        provider.validateProviderSetup()
        http.requests.clear()
        http.mapTileDelayMillis = 150

        var first: Map<String, Any?>? = null
        var second: Map<String, Any?>? = null
        val firstThread = thread {
            first = provider.watchTile(54, 63, 16, themeMode = 0)
        }
        Thread.sleep(25)
        val secondThread = thread {
            second = provider.watchTile(54, 63, 16, themeMode = 0)
        }
        firstThread.join()
        secondThread.join()

        assertEquals(true, first?.get("ok"))
        assertEquals(true, second?.get("ok"))
        assertEquals(
            1,
            http.requests.count { it.url.contains("2dtiles") }
        )
    }

    @Test
    fun mapTileSettingsChangeGoogleSessionParametersAndClearSessions() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        provider.setMapTileSettings(
            GoogleMapTilesProvider.MapTileSettings(
                mapSource = GoogleMapTilesProvider.MapTileSettings.SOURCE_HYBRID,
                watchTileWidth = 72,
                watchTileHeight = 84
            )
        )
        val settingsResult = provider.updateMapTileSettings(
            GoogleMapTilesProvider.MapTileSettings(
                mapSource = GoogleMapTilesProvider.MapTileSettings.SOURCE_TERRAIN
            )
        )
        provider.validateProviderSetup()

        assertEquals(true, settingsResult["ok"])
        val sessionBody = JSONObject(
            http.requests.first { it.url.contains("createSession") && it.headers["X-Android-Package"] == PACKAGE_NAME }
                .body!!.toString(Charsets.UTF_8)
        )
        assertEquals("terrain", sessionBody.getString("mapType"))
        assertEquals("scaleFactor1x", sessionBody.getString("scale"))
        assertEquals(false, sessionBody.getBoolean("highDpi"))
        assertEquals(false, sessionBody.has("imageFormat"))
        assertEquals("layerRoadmap", sessionBody.getJSONArray("layerTypes").getString(0))
    }

    @Test
    fun hybridMapTileSettingsRequestSatelliteRoadLayerAndOverlayDisabled() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        provider.updateMapTileSettings(
            GoogleMapTilesProvider.MapTileSettings(
                mapSource = GoogleMapTilesProvider.MapTileSettings.SOURCE_HYBRID
            )
        )
        provider.validateProviderSetup()

        val sessionBody = JSONObject(
            http.requests.first { it.url.contains("createSession") && it.headers["X-Android-Package"] == PACKAGE_NAME }
                .body!!.toString(Charsets.UTF_8)
        )
        assertEquals("satellite", sessionBody.getString("mapType"))
        assertEquals("layerRoadmap", sessionBody.getJSONArray("layerTypes").getString(0))
        assertEquals(false, sessionBody.getBoolean("overlay"))
    }

    @Test
    fun mapTileSettingsInvalidatesCachedMapTilesSession() {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        provider.validateProviderSetup()
        val sessionsBeforeSettingsChange = http.requests.count { it.url.contains("createSession") }
        provider.updateMapTileSettings(
            GoogleMapTilesProvider.MapTileSettings(
                mapSource = GoogleMapTilesProvider.MapTileSettings.SOURCE_SATELLITE
            )
        )
        provider.previewTile(37.4222804, -122.0843428, 16)
        val sessionsAfterSettingsChange = http.requests.count { it.url.contains("createSession") }

        assertEquals(2, sessionsBeforeSettingsChange)
        assertEquals(4, sessionsAfterSettingsChange)
    }

    private fun sessionBodyForSettings(settings: GoogleMapTilesProvider.MapTileSettings): JSONObject {
        val http = FakeGoogleHttpClient()
        val provider = GoogleMapTilesProvider(FakeCredentialStore(), FakeIdentityProvider(), http, FakeBinaryStringEncoder())

        provider.updateMapTileSettings(settings)
        provider.validateProviderSetup()

        return JSONObject(
            http.requests.first { it.url.contains("createSession") && it.headers["X-Android-Package"] == PACKAGE_NAME }
                .body!!.toString(Charsets.UTF_8)
        )
    }

    private fun assertWatchTileCrop(
        worldX: Int,
        worldY: Int,
        zoom: Int,
        tileDimension: Int
    ) {
        val provider = GoogleMapTilesProvider(
            keyStore = FakeCredentialStore(),
            identityProvider = FakeIdentityProvider(),
            httpClient = FakeGoogleHttpClient(),
            binaryStringEncoder = FakeBinaryStringEncoder(),
            sourceTileDecoder = FixtureSourceTileDecoder(tileDimension)
        )
        provider.setMapTileSettings(GoogleMapTilesProvider.MapTileSettings())

        val result = provider.watchTile(worldX, worldY, zoom, themeMode = 0)
        val payload = result["chunk_data"] as? ByteArray

        assertEquals(true, result["ok"])
        assertNotNull(payload)
        assertEquals(expectedPaletteGrid(worldX, worldY, zoom), decodeRlePaletteIndexes(payload))
    }

    private fun expectedPaletteGrid(worldX: Int, worldY: Int, zoom: Int): List<Int> {
        val worldSize = (1 shl zoom) * 256
        return List(54 * 63) { index ->
            val pixelX = index % 54
            val pixelY = index / 54
            val sourceWorldX = (worldX + pixelX).floorMod(worldSize)
            val sourceWorldY = (worldY + pixelY).coerceIn(0, worldSize - 1)
            val tileX = (sourceWorldX / 256).floorMod(1 shl zoom)
            val tileY = (sourceWorldY / 256).coerceIn(0, (1 shl zoom) - 1)
            fixtureExpectedPaletteIndex(tileX, tileY)
        }
    }

    private fun decodeRlePaletteIndexes(payload: ByteArray): List<Int> {
        val indexes = mutableListOf<Int>()
        payload.forEach { byte ->
            val value = byte.toInt() and 0xFF
            val runLength = (value ushr 4) + 1
            val paletteIndex = value and 0x0F
            repeat(runLength) { indexes.add(paletteIndex) }
        }
        return indexes
    }

    private fun fixturePaletteIndex(tileX: Int, tileY: Int): Int =
        when ((tileX and 1) to (tileY and 1)) {
            1 to 0 -> 1
            0 to 1 -> 2
            1 to 1 -> 3
            else -> 0
        }

    private fun fixtureExpectedPaletteIndex(tileX: Int, tileY: Int): Int =
        expectedDayPaletteIndex(fixturePaletteColor(fixturePaletteIndex(tileX, tileY)))

    private fun fixturePaletteColor(index: Int): Int =
        when (index) {
            1 -> rgb(229, 230, 223)
            2 -> rgb(208, 219, 203)
            3 -> rgb(168, 194, 166)
            else -> rgb(248, 247, 240)
        }

    private fun expectedDayPaletteIndex(color: Int): Int {
        val pebbleColor = rgbaToPebbleDay(color)
        val pebbleRgb = rgb(
            ((pebbleColor ushr 4) and 0x03) * 85,
            ((pebbleColor ushr 2) and 0x03) * 85,
            (pebbleColor and 0x03) * 85
        )
        var bestIndex = 0
        var bestDistance = Int.MAX_VALUE
        DAY_PALETTE_RGB.forEachIndexed { index, candidate ->
            val dr = red(pebbleRgb) - red(candidate)
            val dg = green(pebbleRgb) - green(candidate)
            val db = blue(pebbleRgb) - blue(candidate)
            val distance = dr * dr + dg * dg + db * db
            if (distance < bestDistance) {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private fun rgbaToPebbleDay(color: Int): Int {
        var red = red(color).toDouble()
        var green = green(color).toDouble()
        var blue = blue(color).toDouble()
        val brightness = -10.0
        red = (red + brightness).coerceIn(0.0, 255.0)
        green = (green + brightness).coerceIn(0.0, 255.0)
        blue = (blue + brightness).coerceIn(0.0, 255.0)
        val average = (red + green + blue) / 3.0
        val saturationBoost = 3.0
        red = (average + (red - average) * saturationBoost).coerceIn(0.0, 255.0)
        green = (average + (green - average) * saturationBoost).coerceIn(0.0, 255.0)
        blue = (average + (blue - average) * saturationBoost).coerceIn(0.0, 255.0)
        val gamma = 1.8
        red = Math.pow(red / 255.0, gamma) * 255.0
        green = Math.pow(green / 255.0, gamma) * 255.0
        blue = Math.pow(blue / 255.0, gamma) * 255.0
        return 0xC0 or
            (quantize2(red.toInt()) shl 4) or
            (quantize2(green.toInt()) shl 2) or
            quantize2(blue.toInt())
    }

    private fun quantize2(value: Int): Int = ((value + 42) / 85).coerceIn(0, 3)

    private fun rgb(red: Int, green: Int, blue: Int): Int =
        (0xFF shl 24) or ((red and 0xFF) shl 16) or
            ((green and 0xFF) shl 8) or (blue and 0xFF)

    private fun red(color: Int): Int = (color ushr 16) and 0xFF

    private fun green(color: Int): Int = (color ushr 8) and 0xFF

    private fun blue(color: Int): Int = color and 0xFF

    private fun longRouteBody(pointCount: Int, stepCount: Int): String {
        val routePoints = List(pointCount) { index ->
            37.0 + index * 0.00005 to
                -122.0 + index * 0.00003 + if (index % 2 == 0) -0.0008 else 0.0008
        }
        return routeBody(routePoints, stepCount)
    }

    private fun routeBody(routePoints: List<Pair<Double, Double>>, stepCount: Int): String {
        val steps = JSONArray()
        repeat(stepCount) { index ->
            val point = routePoints[index % routePoints.size]
            steps.put(
                JSONObject()
                    .put(
                        "startLocation",
                        JSONObject().put(
                            "latLng",
                            JSONObject()
                                .put("latitude", point.first)
                                .put("longitude", point.second)
                        )
                    )
                    .put("distanceMeters", 10 + index)
                    .put("staticDuration", "${5 + index}s")
                    .put(
                        "navigationInstruction",
                        JSONObject().put(
                            "instructions",
                            "Continue on synthetic provider adapter route step $index with extra text"
                        )
                    )
            )
        }
        val route = JSONObject()
            .put("distanceMeters", 8000)
            .put("duration", "1800s")
            .put("polyline", JSONObject().put("encodedPolyline", encodePolyline(routePoints)))
            .put("legs", JSONArray().put(JSONObject().put("steps", steps)))
        return JSONObject()
            .put("routes", JSONArray().put(route))
            .toString()
    }

    private fun encodePolyline(points: List<Pair<Double, Double>>): String {
        val builder = StringBuilder()
        var previousLatitude = 0
        var previousLongitude = 0
        points.forEach { point ->
            val latitude = (point.first * 100_000).toInt()
            val longitude = (point.second * 100_000).toInt()
            encodePolylineDelta(latitude - previousLatitude, builder)
            encodePolylineDelta(longitude - previousLongitude, builder)
            previousLatitude = latitude
            previousLongitude = longitude
        }
        return builder.toString()
    }

    private fun encodePolylineDelta(delta: Int, builder: StringBuilder) {
        var value = delta shl 1
        if (delta < 0) {
            value = value.inv()
        }
        while (value >= 0x20) {
            builder.append(((0x20 or (value and 0x1f)) + 63).toChar())
            value = value shr 5
        }
        builder.append((value + 63).toChar())
    }

    private fun Int.floorMod(modulus: Int): Int = ((this % modulus) + modulus) % modulus

    private class FixtureSourceTileDecoder(
        private val tileDimension: Int
    ) : SourceTileDecoder {
        override fun decode(bytes: ByteArray): SourceTileRaster? {
            val parts = bytes.toString(Charsets.UTF_8).split(":")
            if (parts.size != 3) {
                return null
            }
            val tileX = parts[1].toIntOrNull() ?: return null
            val tileY = parts[2].toIntOrNull() ?: return null
            return FixtureSourceTileRaster(tileX, tileY, tileDimension)
        }
    }

    private class FixtureSourceTileRaster(
        private val tileX: Int,
        private val tileY: Int,
        private val tileDimension: Int
    ) : SourceTileRaster {
        override val width: Int = tileDimension
        override val height: Int = tileDimension

        override fun getPixel(x: Int, y: Int): Int =
            fixturePaletteColor(fixturePaletteIndexForTile())

        private fun fixturePaletteIndexForTile(): Int =
            when ((tileX and 1) to (tileY and 1)) {
                1 to 0 -> 1
                0 to 1 -> 2
                1 to 1 -> 3
                else -> 0
            }

        private fun fixturePaletteColor(index: Int): Int =
            when (index) {
                1 -> rgb(229, 230, 223)
                2 -> rgb(208, 219, 203)
                3 -> rgb(168, 194, 166)
                else -> rgb(248, 247, 240)
            }

        private fun rgb(red: Int, green: Int, blue: Int): Int =
            (0xFF shl 24) or ((red and 0xFF) shl 16) or
                ((green and 0xFF) shl 8) or (blue and 0xFF)
    }

    private class FakeCredentialStore : GoogleCredentialStore {
        private var key: String? = "test-google-key"
        private var status: Map<String, Any?> = mapOf(
            "configured" to true,
            "validationState" to ApiKeyStore.STATE_NOT_VALIDATED,
            "validationDetail" to null,
            "packageName" to PACKAGE_NAME,
            "certSha1" to CERT_SHA1
        )

        override fun storeApiKey(plaintext: String): Map<String, Any?> {
            key = plaintext
            return getStatus()
        }

        override fun clearApiKey(): Map<String, Any?> {
            key = null
            status = mapOf(
                "configured" to false,
                "validationState" to ApiKeyStore.STATE_NOT_CONFIGURED
            )
            return getStatus()
        }

        override fun getPlaintextKey(): String? = key

        override fun getStatus(): Map<String, Any?> = status

        override fun clearValidationStatus(): Map<String, Any?> {
            status = if (key == null) {
                mapOf(
                    "configured" to false,
                    "validationState" to ApiKeyStore.STATE_NOT_CONFIGURED
                )
            } else {
                mapOf(
                    "configured" to true,
                    "validationState" to ApiKeyStore.STATE_NOT_VALIDATED,
                    "validationDetail" to null,
                    "packageName" to PACKAGE_NAME,
                    "certSha1" to CERT_SHA1
                )
            }
            return status
        }

        override fun markValidationResult(
            validationState: String,
            validationDetail: String?,
            httpStatus: Int?,
            packageName: String,
            certSha1: String
        ): Map<String, Any?> {
            status = mapOf(
                "configured" to (key != null),
                "validationState" to validationState,
                "validationDetail" to validationDetail,
                "validationHttpStatus" to httpStatus,
                "packageName" to packageName,
                "certSha1" to certSha1
            )
            return status
        }
    }

    private class FakeIdentityProvider : AndroidIdentityProvider {
        override fun currentIdentity(): AndroidIdentity =
            AndroidIdentity(PACKAGE_NAME, CERT_SHA1)
    }

    private class FakeBinaryStringEncoder : BinaryStringEncoder {
        override fun encode(bytes: ByteArray): String = "encoded-${bytes.size}"
    }

    private class FakeGoogleHttpClient(
        private val routeBody: String = DEFAULT_ROUTE_BODY,
        private val mapTileHttpStatus: Int = 200,
        var mapTileDelayMillis: Long = 0
    ) : GoogleHttpClient {
        val requests = mutableListOf<GoogleHttpRequest>()

        override fun execute(request: GoogleHttpRequest): GoogleHttpResponse {
            requests.add(request)
            val wrongPackage = request.headers["X-Android-Package"]?.endsWith(".wrong") == true
            return when {
                request.url.contains("createSession") && wrongPackage -> jsonResponse(
                    403,
                    """{"error":{"message":"Android package is not allowed."}}"""
                )
                request.url.contains("createSession") -> jsonResponse(
                    200,
                    """{"tileWidth":256,"tileHeight":256,"session":"session-token"}"""
                )
                request.url.contains("2dtiles") && mapTileHttpStatus in 200..299 -> {
                    if (mapTileDelayMillis > 0) {
                        Thread.sleep(mapTileDelayMillis)
                    }
                    val tileMarker = request.url
                        .substringAfter("/2dtiles/")
                        .substringBefore("?")
                        .split("/")
                        .let { parts ->
                            "tile:${parts.getOrNull(1) ?: "0"}:${parts.getOrNull(2) ?: "0"}"
                        }
                    GoogleHttpResponse(
                        httpStatus = 200,
                        bodyText = tileMarker,
                        bodyBytes = tileMarker.toByteArray()
                    )
                }
                request.url.contains("2dtiles") -> jsonResponse(
                    mapTileHttpStatus,
                    """{"error":{"message":"Synthetic tile failure."}}"""
                )
                request.url.contains("geocode/json") && wrongPackage -> jsonResponse(
                    200,
                    """{"results":[],"status":"REQUEST_DENIED","error_message":"Android package is not allowed."}"""
                )
                request.url.contains("geocode/json") -> jsonResponse(
                    200,
                    """
                    {
                      "results": [
                        {
                          "formatted_address": "1600 Amphitheatre Pkwy, Mountain View, CA 94043, USA",
                          "geometry": {
                            "location": {
                              "lat": 37.4222804,
                              "lng": -122.0843428
                            }
                          },
                          "place_id": "test-place-id"
                        }
                      ],
                      "status": "OK"
                    }
                    """.trimIndent()
                )
                request.url.contains("places:autocomplete") && wrongPackage -> jsonResponse(
                    403,
                    """{"error":{"message":"Android package is not allowed."}}"""
                )
                request.url.contains("places:autocomplete") -> jsonResponse(
                    200,
                    """
                    {
                      "suggestions": [
                        {
                          "placePrediction": {
                            "placeId": "test-place-id",
                            "text": {"text": "Googleplex, Mountain View, CA, USA"},
                            "structuredFormat": {
                              "mainText": {"text": "Googleplex"},
                              "secondaryText": {"text": "Mountain View, CA, USA"}
                            }
                          }
                        }
                      ]
                    }
                    """.trimIndent()
                )
                request.url.contains("places/") && wrongPackage -> jsonResponse(
                    403,
                    """{"error":{"message":"Android package is not allowed."}}"""
                )
                request.url.contains("places/") -> jsonResponse(
                    200,
                    """
                    {
                      "id": "test-place-id",
                      "displayName": {"text": "Googleplex"},
                      "formattedAddress": "1600 Amphitheatre Pkwy, Mountain View, CA 94043, USA",
                      "location": {
                        "latitude": 37.4222804,
                        "longitude": -122.0843428
                      }
                    }
                    """.trimIndent()
                )
                request.url.contains("computeRoutes") && wrongPackage -> jsonResponse(
                    403,
                    """{"error":{"message":"Android package is not allowed."}}"""
                )
                request.url.contains("computeRoutes") -> jsonResponse(
                    200,
                    routeBody
                )
                else -> jsonResponse(404, """{"error":{"message":"Unexpected fake request."}}""")
            }
        }

        private fun jsonResponse(httpStatus: Int, bodyText: String): GoogleHttpResponse =
            GoogleHttpResponse(
                httpStatus = httpStatus,
                bodyText = bodyText,
                bodyBytes = bodyText.toByteArray()
            )

        private companion object {
            private const val DEFAULT_ROUTE_BODY = """
                {
                  "routes": [
                    {
                      "distanceMeters": 1200,
                      "duration": "420s",
                      "polyline": {
                        "encodedPolyline": "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
                      },
                      "legs": [
                        {
                          "steps": [
                            {
                              "startLocation": {
                                "latLng": {
                                  "latitude": 38.5,
                                  "longitude": -120.2
                                }
                              },
                              "distanceMeters": 1200,
                              "staticDuration": "420s",
                              "navigationInstruction": {
                                "instructions": "Head north"
                              }
                            }
                          ]
                        }
                      ]
                    }
                  ]
                }
            """
        }
    }

    private companion object {
        private const val PACKAGE_NAME = "com.leapwardkoex.mappy"
        private const val CERT_SHA1 = "0123456789ABCDEF0123456789ABCDEF01234567"
        private val DAY_PALETTE_RGB = intArrayOf(
            0xFFFFFFFF.toInt(),
            0xFFFFAAFF.toInt(),
            0xFFAAAAFF.toInt(),
            0xFFAAAAAA.toInt(),
            0xFFAA55AA.toInt(),
            0xFF555555.toInt(),
            0xFF000000.toInt(),
            0xFF55FFFF.toInt(),
            0xFF00AAFF.toInt(),
            0xFF0055FF.toInt(),
            0xFFAAFFAA.toInt(),
            0xFF55FFAA.toInt(),
            0xFFFFFFAA.toInt(),
            0xFFFFFF00.toInt(),
            0xFFFFAA00.toInt(),
            0xFFAAAA55.toInt()
        )
    }
}
