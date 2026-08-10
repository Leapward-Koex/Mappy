package com.leapwardkoex.mappy

import org.json.JSONArray
import org.json.JSONObject
import java.util.Base64
import kotlin.math.roundToInt

internal object PebbleAppMessageCodec {
    private const val JSON_KEY = "key"
    private const val JSON_TYPE = "type"
    private const val JSON_LENGTH = "length"
    private const val JSON_VALUE = "value"

    private const val TYPE_BYTES = "bytes"
    private const val TYPE_STRING = "string"
    private const val TYPE_UINT = "uint"
    private const val TYPE_INT = "int"
    private const val WIDTH_NONE = 0
    private const val WIDTH_WORD = 4

    private val messageKeyNames = WATCH_MESSAGE_KEY_IDS.entries.associate { (name, id) -> id to name }

    fun encode(fields: Map<String, Any?>): String {
        val tuples = JSONArray()
        fields.forEach { (name, value) ->
            val key = WATCH_MESSAGE_KEY_IDS[name] ?: return@forEach
            val tuple = encodeTuple(key, value) ?: return@forEach
            tuples.put(tuple)
        }
        return tuples.toString()
    }

    fun decode(json: String): Map<String, Any?> {
        val output = linkedMapOf<String, Any?>()
        val tuples = JSONArray(json)
        for (index in 0 until tuples.length()) {
            val tuple = tuples.getJSONObject(index)
            val name = messageKeyNames[tuple.getInt(JSON_KEY)] ?: continue
            output[name] = decodeTuple(tuple)
        }
        return output
    }

    private fun encodeTuple(key: Int, value: Any?): JSONObject? {
        if (value == null) {
            return null
        }
        val tuple = JSONObject().put(JSON_KEY, key)
        return when (value) {
            is ByteArray -> tuple
                .put(JSON_TYPE, TYPE_BYTES)
                .put(JSON_LENGTH, WIDTH_NONE)
                .put(JSON_VALUE, Base64.getEncoder().encodeToString(value))
            is String -> tuple
                .put(JSON_TYPE, TYPE_STRING)
                .put(JSON_LENGTH, WIDTH_NONE)
                .put(JSON_VALUE, value)
            is List<*> -> {
                val bytes = value.mapNotNull { (it as? Number)?.toByte() }.toByteArray()
                tuple
                    .put(JSON_TYPE, TYPE_BYTES)
                    .put(JSON_LENGTH, WIDTH_NONE)
                    .put(JSON_VALUE, Base64.getEncoder().encodeToString(bytes))
            }
            is Int -> intTuple(tuple, value)
            is Long -> intTuple(tuple, value.toInt())
            is Double -> if (value.isFinite()) intTuple(tuple, value.roundToInt()) else null
            is Float -> if (value.isFinite()) intTuple(tuple, value.roundToInt()) else null
            is Number -> intTuple(tuple, value.toInt())
            else -> null
        }
    }

    private fun intTuple(tuple: JSONObject, value: Int): JSONObject =
        tuple
            .put(JSON_TYPE, TYPE_INT)
            .put(JSON_LENGTH, WIDTH_WORD)
            .put(JSON_VALUE, value)

    private fun decodeTuple(tuple: JSONObject): Any? =
        when (tuple.getString(JSON_TYPE)) {
            TYPE_BYTES -> Base64.getDecoder().decode(tuple.getString(JSON_VALUE))
            TYPE_STRING -> tuple.getString(JSON_VALUE)
            TYPE_INT, TYPE_UINT -> tuple.getLong(JSON_VALUE).toInt()
            else -> null
        }
}
