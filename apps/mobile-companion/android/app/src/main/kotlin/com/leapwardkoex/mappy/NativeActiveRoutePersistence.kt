package com.leapwardkoex.mappy

import android.content.Context
import org.json.JSONObject

internal data class PersistedActiveRouteRequest(
    val requestId: Int,
    val originPolicy: String,
    val origin: NativeRouteEndpoint?,
    val destination: NativeRouteEndpoint,
    val travelMode: Int,
    val savedSlot: Int?,
    val updatedAtMillis: Long
)

internal object NativeActiveRoutePersistence {
    fun read(context: Context, nowMillis: Long = System.currentTimeMillis()): PersistedActiveRouteRequest? {
        val preferences = context.getSharedPreferences(ACTIVE_ROUTE_PREFERENCES_NAME, Context.MODE_PRIVATE)
        val raw = preferences.getString(ACTIVE_ROUTE_PREFERENCES_KEY, null) ?: return null
        val request = runCatching { parse(JSONObject(raw)) }.getOrNull()
        if (request == null || nowMillis - request.updatedAtMillis > ACTIVE_ROUTE_TTL_MILLIS) {
            clear(context)
            return null
        }
        return request
    }

    fun write(context: Context, request: PersistedActiveRouteRequest) {
        val json = JSONObject()
            .put("schemaVersion", 1)
            .put("requestId", request.requestId)
            .put("originPolicy", request.originPolicy)
            .put("travelMode", request.travelMode)
            .put("savedSlot", request.savedSlot ?: JSONObject.NULL)
            .put("updatedAtMillis", request.updatedAtMillis)
            .put("destination", endpointJson(request.destination))
        request.origin?.let { json.put("origin", endpointJson(it)) }
        context.getSharedPreferences(ACTIVE_ROUTE_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(ACTIVE_ROUTE_PREFERENCES_KEY, json.toString())
            .commit()
    }

    fun clear(context: Context, requestId: Int? = null): Boolean {
        if (requestId != null) {
            val current = read(context) ?: return false
            if (current.requestId != requestId) return false
        }
        context.getSharedPreferences(ACTIVE_ROUTE_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(ACTIVE_ROUTE_PREFERENCES_KEY)
            .commit()
        return true
    }

    private fun parse(json: JSONObject): PersistedActiveRouteRequest? {
        if (json.optInt("schemaVersion", 0) != 1) return null
        val requestId = json.optInt("requestId", 0)
        val originPolicy = json.optString("originPolicy", "")
        val destination = endpoint(json.optJSONObject("destination")) ?: return null
        val origin = endpoint(json.optJSONObject("origin"))
        val updatedAt = json.optLong("updatedAtMillis", 0L)
        if (requestId <= 0 || updatedAt <= 0L ||
            originPolicy !in setOf(ROUTE_ORIGIN_CURRENT_LOCATION, ROUTE_ORIGIN_EXPLICIT_PLACE) ||
            (originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE && origin == null)
        ) return null
        return PersistedActiveRouteRequest(
            requestId = requestId,
            originPolicy = originPolicy,
            origin = origin,
            destination = destination,
            travelMode = travelProtocolValue(json.optInt("travelMode", DEFAULT_TRAVEL_PROTOCOL_MODE)),
            savedSlot = if (json.isNull("savedSlot")) null else json.optInt("savedSlot").takeIf(::isSavedDestinationId),
            updatedAtMillis = updatedAt
        )
    }

    private fun endpointJson(endpoint: NativeRouteEndpoint): JSONObject =
        JSONObject()
            .put("label", endpoint.label)
            .put("address", endpoint.address)
            .put("latitude", endpoint.latitude)
            .put("longitude", endpoint.longitude)
            .put("placeId", endpoint.placeId ?: JSONObject.NULL)

    private fun endpoint(json: JSONObject?): NativeRouteEndpoint? {
        json ?: return null
        val latitude = json.optDouble("latitude", Double.NaN)
        val longitude = json.optDouble("longitude", Double.NaN)
        val label = json.optString("label", "").trim()
        val address = json.optString("address", "").trim()
        if (!latitude.isFinite() || !longitude.isFinite() || latitude !in -90.0..90.0 ||
            longitude !in -180.0..180.0 || label.isBlank() || address.isBlank()
        ) return null
        return NativeRouteEndpoint(
            label = label,
            address = address,
            latitude = latitude,
            longitude = longitude,
            placeId = json.optString("placeId", "").takeIf { it.isNotBlank() }
        )
    }
}
