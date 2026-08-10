package com.leapwardkoex.mappy

import android.content.Context

internal data class NativeDisplaySettings(
    val themeMode: Int,
    val travelMode: Int,
    val unitsMode: Int,
    val backlightMode: Int,
    val mapOrientation: Int,
    val tileAnimationMode: Int
)

internal fun loadNativeDisplaySettings(context: Context): NativeDisplaySettings {
    val preferences = context.getSharedPreferences(DISPLAY_SETTINGS_PREFERENCES_NAME, Context.MODE_PRIVATE)
    return NativeDisplaySettings(
        themeMode = themeProtocolValue(preferences.getInt(THEME_MODE_SETTING, DEFAULT_THEME_MODE)),
        travelMode = travelProtocolValue(preferences.getInt(TRAVEL_MODE_SETTING, DEFAULT_TRAVEL_PROTOCOL_MODE)),
        unitsMode = unitsProtocolValue(preferences.getInt(UNITS_MODE_SETTING, DEFAULT_UNITS_MODE)),
        backlightMode = backlightProtocolValue(preferences.getInt(BACKLIGHT_MODE_SETTING, DEFAULT_BACKLIGHT_MODE)),
        mapOrientation = mapOrientationProtocolValue(
            preferences.getInt(MAP_ORIENTATION_SETTING, DEFAULT_MAP_ORIENTATION)
        ),
        tileAnimationMode = tileAnimationProtocolValue(
            preferences.getInt(TILE_ANIMATION_MODE_SETTING, DEFAULT_TILE_ANIMATION_MODE)
        )
    )
}

internal fun saveNativeDisplaySettings(
    context: Context,
    settings: NativeDisplaySettings
) {
    context.getSharedPreferences(DISPLAY_SETTINGS_PREFERENCES_NAME, Context.MODE_PRIVATE)
        .edit()
        .putInt(THEME_MODE_SETTING, themeProtocolValue(settings.themeMode))
        .putInt(TRAVEL_MODE_SETTING, travelProtocolValue(settings.travelMode))
        .putInt(UNITS_MODE_SETTING, unitsProtocolValue(settings.unitsMode))
        .putInt(BACKLIGHT_MODE_SETTING, backlightProtocolValue(settings.backlightMode))
        .putInt(MAP_ORIENTATION_SETTING, mapOrientationProtocolValue(settings.mapOrientation))
        .putInt(TILE_ANIMATION_MODE_SETTING, tileAnimationProtocolValue(settings.tileAnimationMode))
        .apply()
}

internal fun displaySettingsMap(settings: NativeDisplaySettings): Map<String, Any?> =
    mapOf(
        THEME_MODE_SETTING to settings.themeMode,
        TRAVEL_MODE_SETTING to settings.travelMode,
        UNITS_MODE_SETTING to settings.unitsMode,
        BACKLIGHT_MODE_SETTING to settings.backlightMode,
        MAP_ORIENTATION_SETTING to settings.mapOrientation,
        TILE_ANIMATION_MODE_SETTING to settings.tileAnimationMode
    )

internal fun loadMapTileSettings(context: Context): GoogleMapTilesProvider.MapTileSettings {
    val preferences = context.getSharedPreferences(MAP_TILE_SETTINGS_PREFERENCES_NAME, Context.MODE_PRIVATE)
    return GoogleMapTilesProvider.MapTileSettings.fromMap(
        mapOf(
            "mapSource" to preferences.getString(
                MAP_TILE_SETTING_SOURCE,
                GoogleMapTilesProvider.MapTileSettings.SOURCE_ROADMAP
            ),
            "watchTileSize" to preferences.getString(
                MAP_TILE_SETTING_SIZE,
                "54x63"
            )
        )
    )
}

internal fun saveMapTileSettings(
    context: Context,
    settings: GoogleMapTilesProvider.MapTileSettings
) {
    context.getSharedPreferences(MAP_TILE_SETTINGS_PREFERENCES_NAME, Context.MODE_PRIVATE)
        .edit()
        .clear()
        .putString(MAP_TILE_SETTING_SOURCE, settings.mapSource)
        .putString(MAP_TILE_SETTING_SIZE, "${settings.watchTileWidth}x${settings.watchTileHeight}")
        .apply()
}
