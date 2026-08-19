package com.leapwardkoex.mappy

import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt

private val NAMED_CREDENTIAL_PATTERN = Regex(
    pattern = "(api[_ -]?key|token|secret|credential|password)([:= ]+)\\S+",
    option = RegexOption.IGNORE_CASE
)
private val GOOGLE_API_KEY_PATTERN = Regex("AIza[0-9A-Za-z_-]{16,}")
private val OPAQUE_TOKEN_PATTERN = Regex(
    "(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]{1,15}_[A-Za-z0-9_-]{6,}(?![A-Za-z0-9_-])"
)
private val AUTHORIZATION_HEADER_PATTERN = Regex(
    pattern = "Authorization\\s*[:=]\\s*[^\\r\\n,;]+",
    option = RegexOption.IGNORE_CASE
)
private val BEARER_TOKEN_PATTERN = Regex(
    pattern = "Bearer\\s+[A-Za-z0-9._~+/=-]+",
    option = RegexOption.IGNORE_CASE
)
private val QUERY_CREDENTIAL_PATTERN = Regex(
    pattern = "([?&](?:key|token|sessiontoken|session_token|signature|authorization)=)[^\\s&#]+",
    option = RegexOption.IGNORE_CASE
)

internal fun numberValue(value: Any?): Number? =
    when (value) {
        is Number -> value
        is String -> value.toLongOrNull()
        else -> null
    }

internal fun stringValue(value: Any?): String =
    (value as? String)?.trim().orEmpty()

internal fun boolValue(value: Any?): Boolean? =
    when (value) {
        is Boolean -> value
        is String -> value.equals("true", ignoreCase = true)
        is Number -> value.toInt() != 0
        else -> null
    }

internal fun providerHttpStatus(response: Map<*, *>): Int? =
    intValue(response, "httpStatus")
        ?: (response["providerStatus"] as? Map<*, *>)?.let {
            intValue(it, "validationHttpStatus")
        }

internal fun isoTimestamp(millis: Long): String {
    val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
    formatter.timeZone = TimeZone.getTimeZone("UTC")
    return formatter.format(Date(millis))
}

internal fun jsonObjectToMap(json: JSONObject): Map<String, Any?> {
    val result = linkedMapOf<String, Any?>()
    val keys = json.keys()
    while (keys.hasNext()) {
        val key = keys.next()
        val value = json.opt(key)
        result[key] = if (value == JSONObject.NULL) null else value
    }
    return result
}

internal fun intValue(map: Map<*, *>, key: String): Int? {
    val value = map[key]
    return when (value) {
        is Int -> value
        is Long -> value.toInt()
        is Double -> if (value.isFinite()) value.roundToInt() else null
        is Float -> if (value.isFinite()) value.roundToInt() else null
        is Number -> value.toInt()
        else -> null
    }
}

internal fun doubleValue(map: Map<*, *>, key: String): Double? {
    val value = map[key]
    return when (value) {
        is Double -> if (value.isFinite()) value else null
        is Float -> if (value.isFinite()) value.toDouble() else null
        is Number -> value.toDouble().takeIf { it.isFinite() }
        else -> null
    }
}

internal fun stringValue(map: Map<*, *>, key: String): String =
    (map[key] as? String)?.trim().orEmpty()

internal fun byteArrayValue(value: Any?): ByteArray? =
    when (value) {
        is ByteArray -> value
        is List<*> -> value.mapNotNull { (it as? Number)?.toByte() }.toByteArray()
        else -> null
    }

internal fun listOfMaps(value: Any?): List<Map<*, *>> =
    (value as? List<*>)
        ?.mapNotNull { it as? Map<*, *> }
        .orEmpty()

internal fun isSavedDestinationId(value: Int): Boolean =
    value in 0..MAX_SAVED_DESTINATION_ID

internal fun themeProtocolValue(value: Int?): Int =
    when (value) {
        1 -> 1
        2 -> 2
        else -> DEFAULT_THEME_MODE
    }

internal fun travelProtocolValue(value: Int?): Int =
    when (value) {
        0 -> 0
        1 -> 1
        else -> DEFAULT_TRAVEL_PROTOCOL_MODE
    }

internal fun unitsProtocolValue(value: Int?): Int =
    if (value == 0) 0 else DEFAULT_UNITS_MODE

internal fun backlightProtocolValue(value: Int?): Int =
    if (value == 1) 1 else DEFAULT_BACKLIGHT_MODE

internal fun feedbackModeProtocolValue(value: Int?): Int =
    when (value) {
        0, 1, 2, 3 -> value
        else -> DEFAULT_HAPTIC_MODE
    }

internal fun mapOrientationProtocolValue(value: Int?): Int =
    if (value == 1) 1 else DEFAULT_MAP_ORIENTATION

internal fun tileAnimationProtocolValue(value: Int?): Int =
    when (value) {
        0, 1, 2 -> value
        else -> TILE_ANIMATION_NONE
    }

internal fun providerTravelMode(value: Int): String =
    when (travelProtocolValue(value)) {
        0 -> "walk"
        1 -> "bike"
        else -> DEFAULT_TRAVEL_MODE
    }

internal fun hasSupportedGoogleApiKeyShape(value: String): Boolean =
    GOOGLE_API_KEY_PATTERN.matches(value)

internal fun redactDiagnosticCredentials(
    message: String,
    knownSecrets: Iterable<String> = emptyList()
): String {
    var redacted = NAMED_CREDENTIAL_PATTERN.replace(message) { match ->
        "${match.groupValues[1]}${match.groupValues[2]}[redacted]"
    }
    knownSecrets
        .filter { it.isNotBlank() }
        .forEach { secret -> redacted = redacted.replace(secret, "[redacted]") }
    redacted = GOOGLE_API_KEY_PATTERN.replace(redacted, "AIza...[redacted]")
    redacted = OPAQUE_TOKEN_PATTERN.replace(redacted, "[redacted-opaque-token]")
    redacted = AUTHORIZATION_HEADER_PATTERN.replace(redacted, "Authorization: [redacted]")
    redacted = BEARER_TOKEN_PATTERN.replace(redacted, "Bearer [redacted]")
    return QUERY_CREDENTIAL_PATTERN.replace(redacted) { match ->
        "${match.groupValues[1]}[redacted]"
    }
}
