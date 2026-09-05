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
) {
    fun toChannelMap(): Map<String, Any?> = mapOf(
        "requestId" to requestId,
        "originPolicy" to originPolicy,
        "origin" to origin?.toChannelMap(),
        "destination" to destination.toChannelMap(),
        "travelMode" to travelMode,
        "savedSlot" to savedSlot,
        "updatedAtMillis" to updatedAtMillis
    )
}

private fun NativeRouteEndpoint.toChannelMap(): Map<String, Any?> = mapOf(
    "label" to label,
    "address" to address,
    "latitude" to latitude,
    "longitude" to longitude,
    "placeId" to placeId
)

internal object NativeActiveRoutePersistence {
    fun read(context: Context, nowMillis: Long = System.currentTimeMillis()): PersistedActiveRouteRequest? {
        val preferences = context.getSharedPreferences(ACTIVE_ROUTE_PREFERENCES_NAME, Context.MODE_PRIVATE)
        val raw = preferences.getString(ACTIVE_ROUTE_PREFERENCES_KEY, null) ?: return null
        val request = decode(raw, nowMillis)
        if (request == null) {
            clear(context)
            return null
        }
        return request
    }

    internal fun decode(raw: String, nowMillis: Long): PersistedActiveRouteRequest? {
        val request = runCatching { parse(JSONObject(raw)) }.getOrNull() ?: return null
        val ageMillis = nowMillis - request.updatedAtMillis
        return request.takeIf {
            ageMillis >= -ACTIVE_ROUTE_MAX_FUTURE_SKEW_MILLIS &&
                ageMillis <= ACTIVE_ROUTE_TTL_MILLIS
        }
    }

    fun write(context: Context, request: PersistedActiveRouteRequest): Boolean {
        val json = JSONObject()
            .put("schemaVersion", 1)
            .put("requestId", request.requestId)
            .put("originPolicy", request.originPolicy)
            .put("travelMode", request.travelMode)
            .put("savedSlot", request.savedSlot ?: JSONObject.NULL)
            .put("updatedAtMillis", request.updatedAtMillis)
            .put("destination", endpointJson(request.destination))
        request.origin?.let { json.put("origin", endpointJson(it)) }
        return context.getSharedPreferences(ACTIVE_ROUTE_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(ACTIVE_ROUTE_PREFERENCES_KEY, json.toString())
            .commit()
    }

    fun clear(context: Context, requestId: Int? = null): Boolean {
        if (requestId != null) {
            val current = read(context) ?: return false
            if (current.requestId != requestId) return false
        }
        return context.getSharedPreferences(ACTIVE_ROUTE_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(ACTIVE_ROUTE_PREFERENCES_KEY)
            .commit()
    }

    private fun parse(json: JSONObject): PersistedActiveRouteRequest? {
        if (json.optInt("schemaVersion", 0) != 1) return null
        val requestId = strictInt(json, "requestId") ?: return null
        val originPolicy = json.optString("originPolicy", "")
        val destination = endpoint(json.optJSONObject("destination")) ?: return null
        val origin = endpoint(json.optJSONObject("origin"))
        val travelMode = strictInt(json, "travelMode") ?: return null
        val savedSlot = when {
            !json.has("savedSlot") || json.isNull("savedSlot") -> null
            else -> strictInt(json, "savedSlot")?.takeIf(::isSavedDestinationId)
                ?: return null
        }
        val updatedAt = strictLong(json, "updatedAtMillis") ?: return null
        if (requestId <= 0 || updatedAt <= 0L ||
            originPolicy !in setOf(ROUTE_ORIGIN_CURRENT_LOCATION, ROUTE_ORIGIN_EXPLICIT_PLACE) ||
            (originPolicy == ROUTE_ORIGIN_EXPLICIT_PLACE && origin == null) ||
            travelMode !in 0..DEFAULT_TRAVEL_PROTOCOL_MODE
        ) return null
        return PersistedActiveRouteRequest(
            requestId = requestId,
            originPolicy = originPolicy,
            origin = origin,
            destination = destination,
            travelMode = travelMode,
            savedSlot = savedSlot,
            updatedAtMillis = updatedAt
        )
    }

    private fun strictInt(json: JSONObject, key: String): Int? {
        val value = json.opt(key) as? Number ?: return null
        val longValue = strictLongValue(value) ?: return null
        return longValue.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
    }

    private fun strictLong(json: JSONObject, key: String): Long? {
        val value = json.opt(key) as? Number ?: return null
        return strictLongValue(value)
    }

    private fun strictLongValue(value: Number): Long? {
        val doubleValue = value.toDouble()
        if (!doubleValue.isFinite()) return null
        val longValue = value.toLong()
        return longValue.takeIf { doubleValue == longValue.toDouble() }
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

    private const val ACTIVE_ROUTE_MAX_FUTURE_SKEW_MILLIS = 5 * 60 * 1000L
}
