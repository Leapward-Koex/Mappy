package com.leapwardkoex.mappy

import java.util.UUID

internal const val LOG_TAG = "MappyNative"
internal const val DEFAULT_PREVIEW_ZOOM = 16
internal const val DEFAULT_THEME_MODE = 0
internal const val DEFAULT_TRAVEL_PROTOCOL_MODE = 2
internal const val DEFAULT_UNITS_MODE = 1
internal const val DEFAULT_BACKLIGHT_MODE = 0
internal const val DEFAULT_HAPTIC_MODE = 3
internal const val DEFAULT_GLANCE_MODE = 3
internal const val DEFAULT_MAP_ORIENTATION = 0
internal const val DEFAULT_TILE_ANIMATION_MODE = 1
internal const val TILE_ANIMATION_NONE = 0
internal const val DEFAULT_LANGUAGE = "en-US"
internal const val DEFAULT_REGION = "US"
internal const val DEFAULT_TRAVEL_MODE = "drive"
internal const val ROUTE_ORIGIN_CURRENT_LOCATION = "current_location"
internal const val ROUTE_ORIGIN_EXPLICIT_PLACE = "explicit_place"
internal val WATCH_APP_UUID: UUID = UUID.fromString("18b376dc-40ef-464f-abfb-b1612ea94f7d")
internal const val BRIDGE_METHOD_CHANNEL = "app.mappy.bridge/methods"
internal const val BRIDGE_EVENT_CHANNEL = "app.mappy.bridge/events"
internal const val LOCATION_CHANNEL = "com.leapwardkoex.mappy/location"
internal const val PROVIDER_CHANNEL = "com.leapwardkoex.mappy/provider"
internal const val WATCH_CHANNEL = "com.leapwardkoex.mappy/watch"
internal const val DESTINATION_PREFERENCES_NAME = "mappy_destinations"
internal const val DESTINATION_PREFERENCES_KEY = "destinations_json"
internal const val DIAGNOSTIC_PREFERENCES_NAME = "mappy_diagnostics"
internal const val DIAGNOSTIC_PREFERENCES_KEY = "events_json"
internal const val MAP_TILE_SETTINGS_PREFERENCES_NAME = "mappy_map_tile_settings"
internal const val MAP_TILE_SETTING_SOURCE = "map_source"
internal const val MAP_TILE_SETTING_SIZE = "watch_tile_size"
internal const val DISPLAY_SETTINGS_PREFERENCES_NAME = "watch_display_settings"
internal const val ACTIVE_ROUTE_PREFERENCES_NAME = "mappy_active_route"
internal const val ACTIVE_ROUTE_PREFERENCES_KEY = "active_route_json"
internal const val ACTIVE_ROUTE_TTL_MILLIS = 24 * 60 * 60 * 1000L
internal const val THEME_MODE_SETTING = "themeMode"
internal const val TRAVEL_MODE_SETTING = "travelMode"
internal const val UNITS_MODE_SETTING = "unitsMode"
internal const val BACKLIGHT_MODE_SETTING = "backlightMode"
internal const val HAPTIC_MODE_SETTING = "hapticMode"
internal const val GLANCE_MODE_SETTING = "glanceMode"
internal const val MAP_ORIENTATION_SETTING = "mapOrientation"
internal const val TILE_ANIMATION_MODE_SETTING = "tileAnimationMode"
internal const val LOCATION_PERMISSION_REQUEST_CODE = 6101
internal const val NOTIFICATION_PERMISSION_REQUEST_CODE = 6102
internal const val LOCATION_PERMISSION_REQUESTED_KEY = "location_permission_requested"
internal const val NOTIFICATION_PERMISSION_REQUESTED_KEY = "notification_permission_requested"
internal const val LOCATION_STALE_FOR_UI_MILLIS = 60_000L
internal const val ROUTE_LOCATION_FRESH_MILLIS = 20_000L
internal const val LOCATION_REQUEST_TIMEOUT_MILLIS = 8_000L
internal const val TILE_DIAGNOSTIC_INTERVAL_MILLIS = 2_000L
internal const val SHARE_INTENT_DUPLICATE_WINDOW_MILLIS = 1_500L
internal const val SHARE_REDIRECT_TIMEOUT_MILLIS = 5_000
internal const val MAX_SHARE_REDIRECT_HOPS = 5
internal const val ROUTE_WORLD_ZOOM = 16
internal const val SOURCE_TILE_SIZE = 256.0
internal const val MAX_ROUTE_POINTS = 128
internal const val MAX_NAV_STEP_CHUNK = 3
internal const val MAX_DESTINATION_RECORDS = 0x7f
internal const val MAX_SAVED_DESTINATION_ID = 253
internal const val MAX_DIAGNOSTIC_EVENTS = 2_000
internal const val MAX_DIAGNOSTIC_BYTES = 2 * 1024 * 1024
internal val DIAGNOSTIC_REDACTED_TEXT_KEYS = setOf("message", "detail", "correlation_id")
internal const val MAX_DESTINATION_LABEL_BYTES = 30
internal const val MAX_WATCH_TEXT_BYTES = 47
internal const val MAX_WATCH_TILE_CHUNK_BYTES = 3072
internal const val MIN_WEB_MERCATOR_LAT = -85.05112878
internal const val MAX_WEB_MERCATOR_LAT = 85.05112878
internal const val ERROR_MISSING_KEY = 1
internal const val ERROR_LOCATION_UNAVAILABLE = 3
internal const val ERROR_NETWORK_UNAVAILABLE = 4
internal const val ERROR_TILE_PROVIDER = 5
internal const val ERROR_ROUTE_PROVIDER = 6
internal const val ERROR_NO_ROUTE = 7
internal const val ERROR_DESTINATION_NOT_CONFIGURED = 8
internal const val ERROR_PROTOCOL_MISMATCH = 9
internal const val WATCH_PROTOCOL_VERSION = 3
internal const val KEY_CMD = "cmd"
internal const val KEY_WIDTH = "width"
internal const val KEY_HEIGHT = "height"
internal const val KEY_BYTES_PER_ROW = "bytes_per_row"
internal const val KEY_IS_COLOR = "is_color"
internal const val KEY_COMPRESSION_FORMAT = "compression_format"
internal const val KEY_TOTAL_BYTES = "total_bytes"
internal const val KEY_CHUNK_INDEX = "chunk_index"
internal const val KEY_CHUNK_OFFSET = "chunk_offset"
internal const val KEY_CHUNK_DATA = "chunk_data"
internal const val KEY_BUTTON_ID = "button_id"
internal const val KEY_INSTRUCTION = "instruction"
internal const val KEY_DESTINATION = "destination"
internal const val KEY_WORLD_X = "world_x"
internal const val KEY_WORLD_Y = "world_y"
internal const val KEY_TILE_ZOOM = "tile_zoom"
internal const val KEY_GPS_SEQUENCE = "gps_sequence"
internal const val KEY_GPS_ELAPSED_MS = "gps_elapsed_ms"
internal const val KEY_GPS_ACCURACY_CM = "gps_accuracy_cm"
internal const val KEY_GPS_PROVIDER = "gps_provider"
internal const val KEY_REQUEST_ID = "request_id"
internal const val KEY_PROTOCOL_VERSION = "protocol_version"
internal const val KEY_ERROR_CATEGORY = "errorCategory"
internal const val CMD_INIT = 101
internal const val CMD_ERROR_STATE = 102
internal const val CMD_LOG_EVENT = 103
internal const val CMD_PHONE_READY = 104
internal const val CMD_GPS = 201
internal const val CMD_TILE_REQUEST = 202
internal const val CMD_TILE = 203
internal const val CMD_MAP_SETTINGS = 204
internal const val CMD_MAP_ORIENTATION = 205
internal const val CMD_TILE_ANIMATION = 206
internal const val CMD_BUTTON = 207
internal const val CMD_DESTINATIONS = 301
internal const val CMD_ROUTE_REQUEST = 302
internal const val CMD_ROUTE_POINTS = 303
internal const val CMD_ROUTE_CLEAR = 304
internal const val CMD_NAV_STEPS = 305
internal const val CMD_ROUTE_WINDOW_REQUEST = 306
internal const val CMD_ROUTE_WINDOW_POINTS = 307
internal const val CMD_ROUTE_APPLIED = 308
internal const val CMD_ROUTE_COMPLETE = 309
internal const val CMD_THEME = 401
internal const val CMD_TRAVEL_MODE = 402
internal const val CMD_UNITS = 403
internal const val CMD_BACKLIGHT = 404
internal const val CMD_DECLINATION = 405
internal const val CMD_HAPTIC_MODE = 406
internal const val CMD_GLANCE_MODE = 407
internal const val CMD_DEBUG_COMPASS = 901
internal const val CMD_DEBUG_TILE = 902
internal const val CMD_DEBUG_ROUTE_PROGRESS = 903
internal val WATCH_MESSAGE_KEY_IDS: Map<String, Int> = linkedMapOf(
    KEY_CMD to 50,
    KEY_WIDTH to 51,
    KEY_HEIGHT to 52,
    KEY_BYTES_PER_ROW to 53,
    KEY_IS_COLOR to 54,
    KEY_COMPRESSION_FORMAT to 55,
    KEY_TOTAL_BYTES to 56,
    KEY_CHUNK_INDEX to 57,
    KEY_CHUNK_OFFSET to 58,
    KEY_CHUNK_DATA to 59,
    KEY_BUTTON_ID to 60,
    KEY_INSTRUCTION to 61,
    KEY_DESTINATION to 62,
    KEY_WORLD_X to 63,
    KEY_WORLD_Y to 64,
    KEY_TILE_ZOOM to 65,
    KEY_GPS_SEQUENCE to 66,
    KEY_GPS_ELAPSED_MS to 67,
    KEY_GPS_ACCURACY_CM to 68,
    KEY_GPS_PROVIDER to 69,
    KEY_REQUEST_ID to 70,
    KEY_PROTOCOL_VERSION to 71
)
internal val SHARE_FINAL_GOOGLE_MAPS_HOSTS = setOf(
    "www.google.com",
    "google.com",
    "maps.google.com"
)
internal val SHARE_SHORT_LINK_HOSTS = setOf("maps.app.goo.gl", "goo.gl")
