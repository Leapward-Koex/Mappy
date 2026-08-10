package com.leapwardkoex.mappy

import io.rebble.pebblekit2.common.model.PebbleDictionaryItem

internal object PebbleKit2AppMessageCodec {
    private val messageKeyNames = WATCH_MESSAGE_KEY_IDS.entries.associate { (name, id) -> id to name }

    fun encode(fields: Map<String, Any?>): Map<UInt, PebbleDictionaryItem> =
        linkedMapOf<UInt, PebbleDictionaryItem>().apply {
            fields.forEach { (name, value) ->
                val key = WATCH_MESSAGE_KEY_IDS[name] ?: return@forEach
                val item = encodeItem(value) ?: return@forEach
                put(key.toUInt(), item)
            }
        }

    fun decode(data: Map<UInt, PebbleDictionaryItem>): Map<String, Any?> =
        linkedMapOf<String, Any?>().apply {
            data.forEach { (key, item) ->
                val name = messageKeyNames[key.toInt()] ?: return@forEach
                put(name, decodeItem(item))
            }
        }

    private fun encodeItem(value: Any?): PebbleDictionaryItem? =
        when (value) {
            null -> null
            is ByteArray -> PebbleDictionaryItem.Bytes(value)
            is String -> PebbleDictionaryItem.Text(value)
            is List<*> -> PebbleDictionaryItem.Bytes(
                value.mapNotNull { (it as? Number)?.toByte() }.toByteArray()
            )
            is Int -> PebbleDictionaryItem.Int32(value)
            is Long -> PebbleDictionaryItem.Int32(value.toInt())
            is Double -> if (value.isFinite()) PebbleDictionaryItem.Int32(value.toInt()) else null
            is Float -> if (value.isFinite()) PebbleDictionaryItem.Int32(value.toInt()) else null
            is Number -> PebbleDictionaryItem.Int32(value.toInt())
            else -> null
        }

    private fun decodeItem(item: PebbleDictionaryItem): Any? =
        when (item) {
            is PebbleDictionaryItem.Bytes -> item.value
            is PebbleDictionaryItem.Text -> item.value
            is PebbleDictionaryItem.Int8 -> item.value.toInt()
            is PebbleDictionaryItem.Int16 -> item.value.toInt()
            is PebbleDictionaryItem.Int32 -> item.value
            is PebbleDictionaryItem.UInt8 -> item.value.toInt()
            is PebbleDictionaryItem.UInt16 -> item.value.toInt()
            is PebbleDictionaryItem.UInt32 -> item.value.toInt()
        }
}
