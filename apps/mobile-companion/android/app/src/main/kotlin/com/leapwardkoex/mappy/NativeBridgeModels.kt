package com.leapwardkoex.mappy

internal data class NativeDestination(
    val slot: Int,
    val kind: Int,
    val defaultTravelMode: Int,
    val latitude: Double,
    val longitude: Double,
    val label: String,
    val address: String,
    val placeId: String? = null,
    val updatedAtMillis: Long? = null,
    val geocodeStatus: String = "resolved"
)

internal data class NativeRouteEndpoint(
    val label: String,
    val address: String,
    val latitude: Double,
    val longitude: Double,
    val placeId: String? = null
)

internal data class NativeActiveRouteSnapshot(
    val originPolicy: String,
    val origin: NativeRouteEndpoint?,
    val target: NativeRouteEndpoint?,
    val slot: Int?
)

internal data class NativeActiveRouteMessagesSnapshot(
    val generation: Int,
    val routePoints: List<Map<*, *>>,
    val routeSteps: List<Map<*, *>>,
    val routeMode: Int
)

internal data class NativeRouteWindowSnapshot(
    val generation: Int,
    val fullRoutePoints: List<Map<*, *>>
)

internal data class NativeRoutePointMap(
    val worldX: Int,
    val worldY: Int,
    val raw: Map<*, *>
)

internal data class NativeDestinationUpdate(
    val slot: Int,
    val destination: NativeDestination? = null,
    val error: Map<String, Any?>? = null
)

internal data class ShareRedirectResolution(
    val url: String,
    val hopCount: Int
)

internal data class SharedEndpointResolution(
    val endpoint: NativeRouteEndpoint? = null,
    val error: SharedRouteFailure? = null
)

internal data class SharedRouteFailure(
    val category: Int,
    val detail: String
)
