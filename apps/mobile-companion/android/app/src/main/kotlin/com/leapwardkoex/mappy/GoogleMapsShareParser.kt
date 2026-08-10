package com.leapwardkoex.mappy

import java.net.URI
import java.net.URLDecoder
import java.util.Locale

object GoogleMapsShareParser {
    private const val GOOGLE_MAPS_PACKAGE = "com.google.android.apps.maps"

    private val allowedMapsHosts = setOf(
        "www.google.com",
        "google.com",
        "maps.google.com"
    )
    private val shortLinkHosts = setOf("maps.app.goo.gl", "goo.gl")
    private val uriPattern = Regex(
        "(?i)(https://[^\\s<>\"]+|google\\.navigation:[^\\s<>\"]+|geo:[^\\s<>\"]+)"
    )
    private val coordinatePattern = Regex(
        "([-+]?\\d{1,2}(?:\\.\\d+)?),\\s*([-+]?\\d{1,3}(?:\\.\\d+)?)"
    )
    private val bangCoordinatePattern = Regex(
        "!3d([-+]?\\d{1,2}(?:\\.\\d+)?)!4d([-+]?\\d{1,3}(?:\\.\\d+)?)"
    )
    private val parentheticalLabelPattern = Regex("\\(([^)]{1,100})\\)")

    sealed class Result {
        data class Parsed(val share: Share) : Result()
        data class RedirectRequired(val url: String, val safeHost: String) : Result()
        data class Rejected(val reason: String, val safeHost: String? = null) : Result()
    }

    enum class ShareType(val channelName: String) {
        Location("location"),
        Route("route")
    }

    enum class TravelMode(val channelName: String, val protocolValue: Int) {
        Drive("drive", 2),
        Walk("walk", 0),
        Bike("bike", 1)
    }

    data class Endpoint(
        val label: String?,
        val address: String?,
        val latitude: Double?,
        val longitude: Double?,
        val placeId: String? = null
    ) {
        val hasCoordinates: Boolean
            get() = latitude != null && longitude != null
    }

    data class Share(
        val type: ShareType,
        val safeHost: String,
        val destination: Endpoint,
        val origin: Endpoint? = null,
        val explicitOrigin: Boolean = false,
        val travelMode: TravelMode? = null,
        val redirectHopCount: Int = 0
    )

    fun parse(
        rawText: String,
        sourcePackage: String? = null,
        resolvedUrl: String? = null,
        redirectHopCount: Int = 0
    ): Result {
        val text = rawText.trim()
        if (text.isBlank()) {
            return Result.Rejected("Shared text is empty.")
        }

        val uriText = resolvedUrl?.trim()?.takeIf { it.isNotBlank() }
            ?: extractFirstUri(text)
            ?: return Result.Rejected("No Google Maps URL found.")

        return when {
            uriText.startsWith("https://", ignoreCase = true) ->
                parseHttpsShare(text, uriText, redirectHopCount)
            uriText.startsWith("google.navigation:", ignoreCase = true) ->
                parseGoogleNavigationShare(uriText, redirectHopCount)
            uriText.startsWith("geo:", ignoreCase = true) ->
                parseGeoShare(text, uriText, sourcePackage, redirectHopCount)
            else -> Result.Rejected("Unsupported share URL.")
        }
    }

    fun safeHost(url: String): String? =
        runCatching { URI(url).host?.lowercase(Locale.US) }.getOrNull()

    private fun parseHttpsShare(
        rawText: String,
        url: String,
        redirectHopCount: Int
    ): Result {
        val uri = runCatching { URI(url) }.getOrNull()
            ?: return Result.Rejected("Google Maps URL is malformed.")
        val host = uri.host?.lowercase(Locale.US)
            ?: return Result.Rejected("Google Maps URL is missing a host.")
        if (host in shortLinkHosts) {
            return Result.RedirectRequired(url, host)
        }
        if (host !in allowedMapsHosts) {
            return Result.Rejected("Only Google Maps shares are supported.", host)
        }

        val params = queryParameters(uri.rawQuery)
        if (isRouteUrl(uri, params)) {
            return parseRouteUrl(rawText, uri, params, host, redirectHopCount)
        }
        return parseLocationUrl(rawText, uri, params, host, redirectHopCount)
    }

    private fun parseRouteUrl(
        rawText: String,
        uri: URI,
        params: Map<String, String>,
        host: String,
        redirectHopCount: Int
    ): Result {
        if (hasMultiStopRoute(params)) {
            return Result.Rejected("Multi-stop Google Maps routes are not supported.", host)
        }

        val mode = parseTravelMode(params["travelmode"] ?: params["mode"])
            ?: return Result.Rejected("Unsupported Google Maps travel mode.", host)

        var origin = endpointFromQuery(
            params["origin"],
            params["origin_place_id"],
            fallbackLabel = "Shared origin"
        )
        var destination = endpointFromQuery(
            params["destination"],
            params["destination_place_id"],
            fallbackLabel = "Shared destination"
        )

        val pathEndpoints = routePathEndpoints(uri)
        if (pathEndpoints.size > 2) {
            return Result.Rejected("Multi-stop Google Maps routes are not supported.", host)
        }
        if (destination == null && pathEndpoints.isNotEmpty()) {
            destination = endpointFromText(pathEndpoints.last(), "Shared destination")
        }
        if (origin == null && pathEndpoints.size == 2) {
            origin = endpointFromText(pathEndpoints.first(), "Shared origin")
        }

        if (destination == null) {
            return Result.Rejected("Google Maps route share is missing a destination.", host)
        }

        if (origin?.address?.let { isCurrentLocationText(it) } == true) {
            origin = null
        }

        return Result.Parsed(
            Share(
                type = ShareType.Route,
                safeHost = host,
                destination = destination.withFallbackLabel(shareLabel(rawText) ?: "Shared destination"),
                origin = origin,
                explicitOrigin = origin != null,
                travelMode = mode,
                redirectHopCount = redirectHopCount
            )
        )
    }

    private fun parseLocationUrl(
        rawText: String,
        uri: URI,
        params: Map<String, String>,
        host: String,
        redirectHopCount: Int
    ): Result {
        val shareLabel = shareLabel(rawText)
        val query = firstNonBlank(params["query"], params["q"])
        val placeId = firstNonBlank(params["query_place_id"], params["place_id"])
        val pathLabel = placePathLabel(uri)
        val coordinate = coordinateFromText(query)
            ?: coordinateFromText(uri.rawPath.orEmpty())
            ?: bangCoordinateFromText(uri.rawSchemeSpecificPart.orEmpty())
        val coordinateLabel = labelFromCoordinateText(query)
        val textAddress = query?.takeUnless { coordinateFromText(it) != null }
        val label = firstNonBlank(coordinateLabel, pathLabel, shareLabel, textAddress)
        val address = firstNonBlank(textAddress, pathLabel, shareLabel, label)

        if (coordinate == null && address == null && placeId == null) {
            return Result.Rejected("Shared Google Maps location is missing a place or coordinates.", host)
        }

        return Result.Parsed(
            Share(
                type = ShareType.Location,
                safeHost = host,
                destination = Endpoint(
                    label = label ?: "Shared location",
                    address = address ?: label,
                    latitude = coordinate?.first,
                    longitude = coordinate?.second,
                    placeId = placeId
                ),
                explicitOrigin = false,
                redirectHopCount = redirectHopCount
            )
        )
    }

    private fun parseGoogleNavigationShare(uriText: String, redirectHopCount: Int): Result {
        val body = uriText.substringAfter(':').trimStart('?')
        val params = queryParameters(body)
        val mode = parseTravelMode(params["mode"])
            ?: return Result.Rejected("Unsupported Google Maps travel mode.")
        val destination = endpointFromQuery(params["q"], null, "Shared destination")
            ?: return Result.Rejected("Google navigation share is missing a destination.")
        return Result.Parsed(
            Share(
                type = ShareType.Route,
                safeHost = "google.navigation",
                destination = destination,
                explicitOrigin = false,
                travelMode = mode,
                redirectHopCount = redirectHopCount
            )
        )
    }

    private fun parseGeoShare(
        rawText: String,
        uriText: String,
        sourcePackage: String?,
        redirectHopCount: Int
    ): Result {
        if (sourcePackage != GOOGLE_MAPS_PACKAGE && !rawText.contains("google", ignoreCase = true)) {
            return Result.Rejected("Only Google Maps geo shares are supported.")
        }
        val body = uriText.substringAfter(':')
        val query = body.substringAfter('?', "")
        val params = queryParameters(query)
        val q = params["q"]
        val coordinate = coordinateFromText(q) ?: coordinateFromText(body.substringBefore('?'))
        val label = labelFromCoordinateText(q) ?: shareLabel(rawText)
        val address = q?.takeUnless { coordinateFromText(it) != null } ?: label
        if (coordinate == null && address == null) {
            return Result.Rejected("Geo share is missing a place or coordinates.")
        }
        return Result.Parsed(
            Share(
                type = ShareType.Location,
                safeHost = "geo",
                destination = Endpoint(
                    label = label ?: address ?: "Shared location",
                    address = address ?: label,
                    latitude = coordinate?.first,
                    longitude = coordinate?.second
                ),
                explicitOrigin = false,
                redirectHopCount = redirectHopCount
            )
        )
    }

    private fun extractFirstUri(text: String): String? =
        uriPattern.find(text)
            ?.value
            ?.trim()
            ?.trimEnd('.', ',', ';')

    private fun isRouteUrl(uri: URI, params: Map<String, String>): Boolean {
        val path = uri.rawPath.orEmpty().lowercase(Locale.US)
        return path.contains("/maps/dir") ||
            params.containsKey("destination") ||
            params.containsKey("destination_place_id")
    }

    private fun hasMultiStopRoute(params: Map<String, String>): Boolean =
        listOf("waypoints", "waypoint_place_ids").any { params.containsKey(it) } ||
            params["destination"]?.contains('|') == true ||
            params["origin"]?.contains('|') == true

    private fun routePathEndpoints(uri: URI): List<String> {
        val segments = pathSegments(uri)
        val dirIndex = segments.indexOfFirst { it.equals("dir", ignoreCase = true) }
        if (dirIndex < 0) {
            return emptyList()
        }
        return segments
            .drop(dirIndex + 1)
            .takeWhile { !it.startsWith("@") && !it.startsWith("data=", ignoreCase = true) }
            .filter { it.isNotBlank() }
    }

    private fun placePathLabel(uri: URI): String? {
        val segments = pathSegments(uri)
        val placeIndex = segments.indexOfFirst { it.equals("place", ignoreCase = true) }
        if (placeIndex < 0 || placeIndex + 1 >= segments.size) {
            return null
        }
        return cleanedEndpointText(segments[placeIndex + 1]).takeIf { it.isNotBlank() }
    }

    private fun pathSegments(uri: URI): List<String> =
        uri.rawPath
            ?.split('/')
            ?.map { decodePathComponent(it) }
            ?.filter { it.isNotBlank() && !it.equals("maps", ignoreCase = true) }
            .orEmpty()

    private fun endpointFromQuery(
        value: String?,
        placeId: String?,
        fallbackLabel: String
    ): Endpoint? {
        val text = value?.trim()?.takeIf { it.isNotBlank() }
        if (text == null && placeId.isNullOrBlank()) {
            return null
        }
        return endpointFromText(text ?: fallbackLabel, fallbackLabel, placeId)
    }

    private fun endpointFromText(
        value: String,
        fallbackLabel: String,
        placeId: String? = null
    ): Endpoint {
        val cleaned = cleanedEndpointText(value)
        val coordinate = coordinateFromText(cleaned)
        val coordinateLabel = labelFromCoordinateText(cleaned)
        val isCoordinateOnly = coordinate != null
        val label = firstNonBlank(coordinateLabel, cleaned.takeUnless { isCoordinateOnly }, fallbackLabel)
        val address = cleaned.takeUnless { isCoordinateOnly } ?: label
        return Endpoint(
            label = label,
            address = address,
            latitude = coordinate?.first,
            longitude = coordinate?.second,
            placeId = placeId?.takeIf { it.isNotBlank() }
        )
    }

    private fun Endpoint.withFallbackLabel(fallbackLabel: String): Endpoint =
        if (!label.isNullOrBlank()) {
            this
        } else {
            copy(label = fallbackLabel)
        }

    private fun parseTravelMode(value: String?): TravelMode? {
        val normalized = value?.trim()?.lowercase(Locale.US)
        if (normalized.isNullOrBlank()) {
            return TravelMode.Drive
        }
        return when (normalized) {
            "driving", "drive", "d" -> TravelMode.Drive
            "walking", "walk", "w" -> TravelMode.Walk
            "bicycling", "bicycle", "bike", "b" -> TravelMode.Bike
            "transit", "two_wheeler", "two-wheeler", "motorcycle", "m" -> null
            else -> null
        }
    }

    private fun coordinateFromText(value: String?): Pair<Double, Double>? {
        if (value.isNullOrBlank()) {
            return null
        }
        return coordinatePattern.findAll(value).mapNotNull { match ->
            val latitude = match.groupValues[1].toDoubleOrNull()
            val longitude = match.groupValues[2].toDoubleOrNull()
            if (latitude != null && longitude != null && isValidCoordinate(latitude, longitude)) {
                latitude to longitude
            } else {
                null
            }
        }.firstOrNull()
    }

    private fun bangCoordinateFromText(value: String): Pair<Double, Double>? {
        val match = bangCoordinatePattern.find(value) ?: return null
        val latitude = match.groupValues[1].toDoubleOrNull()
        val longitude = match.groupValues[2].toDoubleOrNull()
        return if (latitude != null && longitude != null && isValidCoordinate(latitude, longitude)) {
            latitude to longitude
        } else {
            null
        }
    }

    private fun labelFromCoordinateText(value: String?): String? =
        value
            ?.let { parentheticalLabelPattern.find(it)?.groupValues?.getOrNull(1) }
            ?.trim()
            ?.takeIf { it.isNotBlank() }

    private fun isValidCoordinate(latitude: Double, longitude: Double): Boolean =
        latitude in -90.0..90.0 && longitude in -180.0..180.0

    private fun queryParameters(rawQuery: String?): Map<String, String> {
        if (rawQuery.isNullOrBlank()) {
            return emptyMap()
        }
        return rawQuery
            .split('&')
            .mapNotNull { pair ->
                val key = pair.substringBefore('=', "").takeIf { it.isNotBlank() } ?: return@mapNotNull null
                val value = pair.substringAfter('=', "")
                decodeQueryComponent(key).lowercase(Locale.US) to decodeQueryComponent(value)
            }
            .toMap()
    }

    private fun shareLabel(text: String): String? =
        text
            .lineSequence()
            .map { it.trim() }
            .firstOrNull { line ->
                line.isNotBlank() &&
                    extractFirstUri(line) == null &&
                    !line.startsWith("http", ignoreCase = true)
            }
            ?.take(80)

    private fun cleanedEndpointText(value: String): String =
        value
            .replace('+', ' ')
            .trim()
            .trimEnd('/', '.', ',', ';')

    private fun isCurrentLocationText(value: String): Boolean {
        val normalized = value.trim().lowercase(Locale.US)
        return normalized == "current location" ||
            normalized == "my location" ||
            normalized == "your location"
    }

    private fun firstNonBlank(vararg values: String?): String? =
        values.firstOrNull { !it.isNullOrBlank() }?.trim()

    private fun decodePathComponent(value: String): String =
        decodeQueryComponent(value).replace('+', ' ')

    private fun decodeQueryComponent(value: String): String =
        runCatching { URLDecoder.decode(value, Charsets.UTF_8.name()) }
            .getOrElse { value }
}
