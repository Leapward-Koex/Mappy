#include "mappy.h"

// Shared runtime state and static render palettes.

Window *s_window;
Layer *s_map_layer;
TileCacheEntry *s_tiles;
uint8_t *s_tile_storage_bytes;
uint8_t *s_tile_decode_scratch;
TileStorageArena s_tile_storage_arena;
int s_tile_cache_size = TILE_CACHE_SIZE;
TileRequest s_request_queue[TILE_CACHE_SIZE];
uint8_t s_request_retry_attempts[TILE_CACHE_SIZE];
int s_request_count;
int s_request_index;
int32_t s_inflight_tile_request_id;
TileFlight s_tile_flights[TILE_REQUEST_MAX_FLIGHTS];
bool s_tile_requests_interaction_paused;
bool s_tile_requests_setup_paused;
AppTimer *s_tile_request_resume_timer;
AppTimer *s_tile_redraw_timer;
TileRequest s_orientation_tile_origins[TILE_CACHE_SIZE];
int s_orientation_tile_origin_count;
bool s_orientation_tile_origins_valid;
bool s_outbox_busy;
int32_t s_outbox_cmd;
uint32_t s_access_counter;
AppTimer *s_visual_animation_timer;
AppTimer *s_tile_request_watchdog_timer;

RoutePoint s_route_points[MAX_ROUTE_POINTS];
RoutePoint s_route_detail_points[MAX_ROUTE_POINTS];
uint16_t s_route_point_count;
uint16_t s_route_detail_point_count;
int8_t s_route_zoom = ROUTE_WORLD_ZOOM;
int8_t s_route_detail_zoom = ROUTE_WORLD_ZOOM;
int32_t s_route_generation;
int32_t s_last_walk_start_feedback_generation = INT32_MIN;
int32_t s_route_detail_generation;
int32_t s_route_detail_center_x;
int32_t s_route_detail_center_y;
int32_t s_route_detail_width;
int32_t s_route_detail_height;
bool s_route_detail_window_valid;
bool s_route_window_request_inflight;
bool s_route_window_request_pending;
DestinationSlot *s_destinations;
uint8_t s_destination_count;
NavStep s_nav_steps[MAX_NAV_STEPS];
int32_t s_nav_step_progress[MAX_NAV_STEPS];
int32_t s_route_total_progress_px;
uint8_t s_nav_total_steps;
uint8_t s_nav_first_global_index;
uint8_t s_nav_step_count;
uint8_t s_current_nav_local_index;
uint8_t s_next_nav_request_index;
int32_t s_last_route_progress = ROUTE_PROGRESS_UNKNOWN;
int16_t s_turn_preview_alerted_global_index = ROUTE_TURN_ALERT_NONE;
int16_t s_turn_now_alerted_global_index = ROUTE_TURN_ALERT_NONE;
bool s_arrival_dialog_visible;
bool s_nav_request_inflight;
bool s_route_projection_unavailable_logged;
bool s_route_offroute_logged;
bool s_route_gps_stale_logged;
bool s_route_clear_pending;
bool s_route_complete_pending;
int32_t s_active_route_request_id;
int32_t s_next_request_id = 1;
bool s_route_applied_pending;
bool s_route_steps_expected;
int s_deferred_route_request_slot = DEFERRED_ROUTE_REQUEST_NONE;
PendingLogEvent s_pending_log_events[LOG_EVENT_QUEUE_SIZE];
uint8_t s_pending_log_head;
uint8_t s_pending_log_count;
uint16_t s_pending_log_overflow_count;

AppState s_state = AppStateBooting;
GRect s_screen_bounds;
int32_t s_viewport_x;
int32_t s_viewport_y;
int8_t s_viewport_zoom = ROUTE_WORLD_ZOOM;
int32_t s_gps_world_x;
int32_t s_gps_world_y;
int32_t s_gps_display_world_x;
int32_t s_gps_display_world_y;
int32_t s_gps_smoothing_start_world_x;
int32_t s_gps_smoothing_start_world_y;
int32_t s_gps_smoothing_target_world_x;
int32_t s_gps_smoothing_target_world_y;
int32_t s_render_viewport_x;
int32_t s_render_viewport_y;
int32_t s_gps_smoothing_start_viewport_x;
int32_t s_gps_smoothing_start_viewport_y;
int32_t s_gps_smoothing_target_viewport_x;
int32_t s_gps_smoothing_target_viewport_y;
int8_t s_gps_zoom = ROUTE_WORLD_ZOOM;
int32_t s_heading_degrees = -1;
int32_t s_compass_heading_degrees = -1;
int32_t s_compass_magnetic_degrees = -1;
int32_t s_map_bearing_display_centi_degrees = -1;
int32_t s_map_bearing_target_centi_degrees = -1;
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
bool s_debug_compass_override_active;
#endif
int32_t s_declination_centi_degrees;
bool s_declination_valid;
time_t s_gps_received_at;
int32_t s_gps_sequence = INT32_MIN;
int32_t s_gps_elapsed_ms = -1;
int32_t s_gps_accuracy_cm = -1;
char s_gps_provider[GPS_PROVIDER_BYTES];
bool s_has_gps_sequence;
bool s_has_gps;
bool s_gps_smoothing_active;
uint8_t s_gps_smoothing_mode = GPS_SMOOTHING_NONE;
time_t s_gps_smoothing_started_s;
uint16_t s_gps_smoothing_started_ms;
uint16_t s_gps_smoothing_duration_ms;
bool s_manual_pan;
int s_theme_mode;
int s_travel_mode = 2;
int s_pending_route_mode = 2;
int s_active_route_mode = 2;
int s_backlight_mode;
int s_map_orientation;
int s_units_mode = 1;
int s_tile_animation_mode = TILE_ANIMATION_FADE;
int s_tile_width = DEFAULT_TILE_W;
int s_tile_height = DEFAULT_TILE_H;
int s_tile_pixels = DEFAULT_TILE_W * DEFAULT_TILE_H;
int s_tile_bytes = (DEFAULT_TILE_W * DEFAULT_TILE_H + 1) / 2;
int32_t s_tile_chunk_world_x;
int32_t s_tile_chunk_world_y;
int8_t s_tile_chunk_zoom;
int s_tile_chunk_width;
int s_tile_chunk_height;
int32_t s_tile_chunk_total;
int32_t s_tile_chunk_received;
int32_t s_tile_chunk_next_index;
int32_t s_tile_chunk_request_id;
bool s_tile_chunk_active;
bool s_tile_chunk_store_packed;
TileRleStreamDecoder s_tile_chunk_decoder;
int s_selected_slot = -1;
int s_pending_route_slot = -1;
int s_active_route_slot = -1;
int s_error_category;
MenuMode s_menu_mode = MenuNone;
int s_menu_selection;
bool s_menu_highlight_active;
int s_menu_highlight_from_selection;
time_t s_menu_highlight_started_s;
uint16_t s_menu_highlight_started_ms;
GRect s_menu_highlight_from_rect;
GRect s_menu_highlight_to_rect;
bool s_route_clear_armed;
char s_top_text[48] = "Map";
char s_bottom_text[64] = "Starting";
char s_instruction[48] = "";
int16_t s_transient_zoom_scale_q8 = TRANSIENT_SCALE_Q8_ONE;

#ifdef PBL_TOUCH
bool s_touch_active;
bool s_touch_subscribed;
int16_t s_touch_start_x;
int16_t s_touch_start_y;
int32_t s_touch_start_viewport_x;
int32_t s_touch_start_viewport_y;
time_t s_last_touch_ended_s;
uint16_t s_last_touch_ended_ms;
bool s_touch_disabled_logged;
bool s_pinch_unavailable_logged;
#endif

const GColor s_day_palette[16] = {
  GColorFromHEX(0xFFFFFF), GColorFromHEX(0xFFAAFF),
  GColorFromHEX(0xAAAAFF), GColorFromHEX(0xAAAAAA),
  GColorFromHEX(0xAA55AA), GColorFromHEX(0x555555),
  GColorFromHEX(0x000000), GColorFromHEX(0x55FFFF),
  GColorFromHEX(0x00AAFF), GColorFromHEX(0x0055FF),
  GColorFromHEX(0xAAFFAA), GColorFromHEX(0x55FFAA),
  GColorFromHEX(0xFFFFAA), GColorFromHEX(0xFFFF00),
  GColorFromHEX(0xFFAA00), GColorFromHEX(0xAAAA55),
};

const GColor s_night_palette[16] = {
  GColorFromHEX(0x000000), GColorFromHEX(0x005500),
  GColorFromHEX(0x000055), GColorFromHEX(0x555555),
  GColorFromHEX(0x005555), GColorFromHEX(0xAAAAAA),
  GColorFromHEX(0xFFFFFF), GColorFromHEX(0x0055AA),
  GColorFromHEX(0x0055FF), GColorFromHEX(0x00AAFF),
  GColorFromHEX(0x00AA00), GColorFromHEX(0x00FF00),
  GColorFromHEX(0x55AA00), GColorFromHEX(0xAAAA00),
  GColorFromHEX(0x00AA55), GColorFromHEX(0x55AA55),
};
