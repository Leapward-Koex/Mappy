package com.leapwardkoex.mappy

import android.content.Context

internal object NativeSetupChecklistPersistence {
    fun read(context: Context): Int {
        val storedVersion = runCatching {
            context.getSharedPreferences(APP_STATE_PREFERENCES_NAME, Context.MODE_PRIVATE)
                .getInt(SETUP_CHECKLIST_VERSION_KEY, 0)
        }.getOrDefault(0)
        return normalizeStoredSetupChecklistVersion(storedVersion)
    }

    fun write(context: Context, version: Int): Boolean {
        if (version < 0) return false
        return context.getSharedPreferences(APP_STATE_PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putInt(SETUP_CHECKLIST_VERSION_KEY, version)
            .commit()
    }
}

internal fun normalizeStoredSetupChecklistVersion(version: Int): Int = version.coerceAtLeast(0)

internal fun setupChecklistVersionArgument(arguments: Any?): Int? {
    val value = if (arguments is Map<*, *>) arguments["version"] else arguments
    return when (value) {
        is Int -> value.takeIf { it >= 0 }
        is Long -> value
            .takeIf { it in 0..Int.MAX_VALUE.toLong() }
            ?.toInt()
        else -> null
    }
}
