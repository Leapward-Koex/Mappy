package com.leapwardkoex.mappy

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

internal fun nativeDestinationMap(destination: NativeDestination): Map<String, Any?> =
    mapOf(
        "slotIndex" to destination.slot,
        "enabled" to true,
        "label" to destination.label,
        "address" to destination.address,
        "latitude" to destination.latitude,
        "longitude" to destination.longitude,
        "kind" to destination.kind,
        "defaultTravelMode" to destination.defaultTravelMode,
        "placeId" to destination.placeId,
        "updatedAtMillis" to destination.updatedAtMillis,
        "geocodeStatus" to destination.geocodeStatus
    )

internal fun parseNativeRouteEndpoint(endpoint: Map<*, *>): NativeRouteEndpoint? {
    val latitude = doubleValue(endpoint, "latitude")
    val longitude = doubleValue(endpoint, "longitude")
    if (latitude == null ||
        longitude == null ||
        latitude !in -90.0..90.0 ||
        longitude !in -180.0..180.0
    ) {
        return null
    }

    val rawLabel = stringValue(endpoint, "label")
    val rawAddress = stringValue(endpoint, "address")
    val label = rawLabel.ifBlank { rawAddress }
    val address = rawAddress.ifBlank { rawLabel }
    if (label.isBlank() || address.isBlank()) {
        return null
    }
    return NativeRouteEndpoint(
        label = label,
        address = address,
        latitude = latitude,
        longitude = longitude,
        placeId = stringValue(endpoint, "placeId").takeIf { it.isNotBlank() }
    )
}

internal fun parseNativeDestinationPayload(
    destination: Map<*, *>,
    errorMessage: (
        category: Int,
        failedCommand: Int,
        text: String,
        offset: Int
    ) -> Map<String, Any?>
): NativeDestinationUpdate {
    val slot = intValue(destination, "slotIndex")
    if (slot == null || !isSavedDestinationId(slot)) {
        return NativeDestinationUpdate(
            slot = slot ?: 0,
            error = errorMessage(
                ERROR_DESTINATION_NOT_CONFIGURED,
                CMD_DESTINATIONS,
                "Destination id is reserved or out of range.",
                slot ?: 0
            )
        )
    }

    val enabled = destination["enabled"] as? Boolean ?: true
    if (!enabled) {
        return NativeDestinationUpdate(slot = slot, destination = null)
    }

    val latitude = doubleValue(destination, "latitude")
    val longitude = doubleValue(destination, "longitude")
    if (latitude == null ||
        longitude == null ||
        latitude !in -90.0..90.0 ||
        longitude !in -180.0..180.0
    ) {
        return NativeDestinationUpdate(
            slot = slot,
            error = errorMessage(
                ERROR_DESTINATION_NOT_CONFIGURED,
                CMD_DESTINATIONS,
                "Destination coordinates are invalid.",
                slot
            )
        )
    }

    val rawLabel = stringValue(destination, "label")
    val rawAddress = stringValue(destination, "address")
    val label = rawLabel.ifBlank { rawAddress }
    val address = rawAddress.ifBlank { rawLabel }
    if (label.isBlank()) {
        return NativeDestinationUpdate(
            slot = slot,
            error = errorMessage(
                ERROR_DESTINATION_NOT_CONFIGURED,
                CMD_DESTINATIONS,
                "Destination label is empty.",
                slot
            )
        )
    }
    if (label.toByteArray(Charsets.UTF_8).size > MAX_DESTINATION_LABEL_BYTES) {
        return NativeDestinationUpdate(
            slot = slot,
            error = errorMessage(
                ERROR_DESTINATION_NOT_CONFIGURED,
                CMD_DESTINATIONS,
                "Destination label is too long.",
                slot
            )
        )
    }

    return NativeDestinationUpdate(
        slot = slot,
        destination = NativeDestination(
            slot = slot,
            kind = (intValue(destination, "kind") ?: 2).coerceIn(0, 2),
            defaultTravelMode = travelProtocolValue(intValue(destination, "defaultTravelMode")),
            latitude = latitude,
            longitude = longitude,
            label = label,
            address = address,
            placeId = stringValue(destination, "placeId").takeIf { it.isNotBlank() },
            updatedAtMillis = numberValue(destination["updatedAtMillis"])?.toLong()
                ?.takeIf { it > 0L }
                ?: System.currentTimeMillis(),
            geocodeStatus = stringValue(destination, "geocodeStatus").ifBlank { "resolved" }
        )
    )
}

internal fun readPersistedNativeDestinations(context: Context): List<NativeDestination>? {
    val raw = context.getSharedPreferences(DESTINATION_PREFERENCES_NAME, Context.MODE_PRIVATE)
        .getString(DESTINATION_PREFERENCES_KEY, null)
        ?: return null
    return try {
        val json = JSONArray(raw)
        buildList {
            val seenSlots = mutableSetOf<Int>()
            for (index in 0 until json.length()) {
                val destination = nativeDestinationFromJson(json.optJSONObject(index) ?: continue)
                    ?: continue
                if (size >= MAX_DESTINATION_RECORDS) {
                    break
                }
                if (seenSlots.add(destination.slot)) {
                    add(destination)
                }
            }
        }
    } catch (_: Exception) {
        null
    }
}

private fun nativeDestinationFromJson(json: JSONObject): NativeDestination? {
    val slot = json.optInt("slot", -1)
    val latitude = json.optDouble("latitude", Double.NaN)
    val longitude = json.optDouble("longitude", Double.NaN)
    val label = json.optString("label", "").trim()
    val address = json.optString("address", "").trim()
    if (!isSavedDestinationId(slot) ||
        !latitude.isFinite() ||
        !longitude.isFinite() ||
        latitude !in -90.0..90.0 ||
        longitude !in -180.0..180.0 ||
        label.isBlank() ||
        label.toByteArray(Charsets.UTF_8).size > MAX_DESTINATION_LABEL_BYTES
    ) {
        return null
    }
    return NativeDestination(
        slot = slot,
        kind = json.optInt("kind", 2).coerceIn(0, 2),
        defaultTravelMode = travelProtocolValue(json.optInt("defaultTravelMode", DEFAULT_TRAVEL_PROTOCOL_MODE)),
        latitude = latitude,
        longitude = longitude,
        label = label,
        address = address.ifBlank { label },
        placeId = json.optString("placeId", "").takeIf { it.isNotBlank() },
        updatedAtMillis = json.optLong("updatedAtMillis", 0L).takeIf { it > 0L },
        geocodeStatus = json.optString("geocodeStatus", "resolved").ifBlank { "resolved" }
    )
}

internal fun persistNativeDestinations(
    context: Context,
    destinations: List<NativeDestination>
) {
    val json = JSONArray()
    destinations
        .sortedBy { it.slot }
        .forEach { destination ->
            json.put(
                JSONObject()
                    .put("slot", destination.slot)
                    .put("kind", destination.kind)
                    .put("defaultTravelMode", destination.defaultTravelMode)
                    .put("latitude", destination.latitude)
                    .put("longitude", destination.longitude)
                    .put("label", destination.label)
                    .put("address", destination.address)
                    .put("placeId", destination.placeId ?: "")
                    .put("updatedAtMillis", destination.updatedAtMillis ?: 0L)
                    .put("geocodeStatus", destination.geocodeStatus)
            )
        }
    context.getSharedPreferences(DESTINATION_PREFERENCES_NAME, Context.MODE_PRIVATE)
        .edit()
        .putString(DESTINATION_PREFERENCES_KEY, json.toString())
        .apply()
}
