#ifndef MAPPY_H
#define MAPPY_H

// Private watch-app header shared by the split native C modules.

#include <pebble.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>
#include <string.h>

#include "bearing_smoothing.h"
#include "motion_detector.h"
#include "pan_inertia.h"
#include "tile_codec.h"
#include "tile_storage.h"

#define CMD_INIT 101
#define CMD_ERROR_STATE 102
#define CMD_LOG_EVENT 103
#define CMD_PHONE_READY 104
#define CMD_GPS 201
#define CMD_TILE_REQUEST 202
#define CMD_TILE 203
#define CMD_MAP_SETTINGS 204
#define CMD_MAP_ORIENTATION 205
#define CMD_TILE_ANIMATION 206
#define CMD_BUTTON 207
#define CMD_DESTINATIONS 301
#define CMD_ROUTE_REQUEST 302
#define CMD_ROUTE_POINTS 303
#define CMD_ROUTE_CLEAR 304
#define CMD_NAV_STEPS 305
#define CMD_ROUTE_WINDOW_REQUEST 306
#define CMD_ROUTE_WINDOW_POINTS 307
#define CMD_ROUTE_APPLIED 308
#define CMD_ROUTE_COMPLETE 309
#define CMD_THEME 401
#define CMD_TRAVEL_MODE 402
#define CMD_UNITS 403
#define CMD_BACKLIGHT 404
#define CMD_DECLINATION 405
#define CMD_DEBUG_COMPASS 901
#define CMD_DEBUG_TILE 902
#define CMD_DEBUG_ROUTE_PROGRESS 903

#ifndef MESSAGE_KEY_cmd
#define MESSAGE_KEY_cmd 50
#define MESSAGE_KEY_width 51
#define MESSAGE_KEY_height 52
#define MESSAGE_KEY_bytes_per_row 53
#define MESSAGE_KEY_is_color 54
#define MESSAGE_KEY_compression_format 55
#define MESSAGE_KEY_total_bytes 56
#define MESSAGE_KEY_chunk_index 57
#define MESSAGE_KEY_chunk_offset 58
#define MESSAGE_KEY_chunk_data 59
#define MESSAGE_KEY_button_id 60
#define MESSAGE_KEY_instruction 61
#define MESSAGE_KEY_destination 62
#define MESSAGE_KEY_world_x 63
#define MESSAGE_KEY_world_y 64
#define MESSAGE_KEY_tile_zoom 65
#define MESSAGE_KEY_gps_sequence 66
#define MESSAGE_KEY_gps_elapsed_ms 67
#define MESSAGE_KEY_gps_accuracy_cm 68
#define MESSAGE_KEY_gps_provider 69
#define MESSAGE_KEY_request_id 70
#define MESSAGE_KEY_protocol_version 71
#endif

#define WATCH_PROTOCOL_VERSION 2

#define DEFAULT_TILE_W 54
#define DEFAULT_TILE_H 63
#define MAX_TILE_W 108
#define MAX_TILE_H 126
#define MAX_TILE_PIXELS (MAX_TILE_W * MAX_TILE_H)
#define MAX_TILE_BYTES ((MAX_TILE_PIXELS + 1) / 2)
#define GRID_COLS 7
#define GRID_ROWS 6
#define TILE_CACHE_SIZE (GRID_COLS * GRID_ROWS)
#define TILE_STORAGE_ARENA_BYTES (46 * 1024)
#define MAX_RLE_BYTES MAX_TILE_PIXELS
#define MAX_ROUTE_POINTS 128
#define MAX_INSTRUCTION_BYTES 47
#define MAX_DESTINATION_RECORDS 127
#define MAX_SAVED_DESTINATION_ID 253
#define DEST_LABEL_BYTES 31
#define MAX_NAV_STEPS 3
#define LOG_EVENT_QUEUE_SIZE 8
#define GPS_PROVIDER_BYTES 16
#define ROUTE_WORLD_ZOOM 16
#define MIN_MAP_ZOOM 14
#define MAX_MAP_ZOOM 18
#define TRANSIENT_SCALE_Q8_ONE 256
#define ROUTE_PROGRESS_UNKNOWN INT32_MIN
#define ROUTE_ADVANCE_METERS 20
#define ROUTE_CLOSER_METERS 10
#define ROUTE_OFF_ROUTE_METERS 60
#define ROUTE_FALLBACK_ADVANCE_PX 8
#define ROUTE_FALLBACK_CLOSER_PX 4
#define ROUTE_FALLBACK_OFF_ROUTE_PX 25
#define ROUTE_VISUAL_OFF_ROUTE_PX ROUTE_FALLBACK_OFF_ROUTE_PX
#define ROUTE_TURN_ALERT_NONE -1
#define ROUTE_TURN_PREVIEW_WALK_METERS 50
#define ROUTE_TURN_PREVIEW_BIKE_METERS 80
#define ROUTE_TURN_PREVIEW_DRIVE_METERS 250
#define ROUTE_TURN_NOW_WALK_METERS 12
#define ROUTE_TURN_NOW_BIKE_METERS 25
#define ROUTE_TURN_NOW_DRIVE_METERS 60
#define ROUTE_TURN_FALLBACK_PREVIEW_PX 20
#define ROUTE_TURN_FALLBACK_NOW_PX 6
#define ROUTE_ARRIVAL_METERS 20
#define ROUTE_ARRIVAL_FALLBACK_PX 8
#define GPS_PROGRESS_FRESH_SECONDS 30
#define HEADING_FRESH_SECONDS GPS_PROGRESS_FRESH_SECONDS
#define DEFERRED_ROUTE_REQUEST_NONE -99
#define ROUTE_DETAIL_MIN_ZOOM ROUTE_WORLD_ZOOM
#define ROUTE_WINDOW_PREFETCH_SCREENS 9
#define ROUTE_WINDOW_MIN_SIZE 256
#define TRAVEL_MODE_WALK 0
#define TRAVEL_MODE_BIKE 1
#define TRAVEL_MODE_DRIVE 2
#define WALK_ROUTE_DOT_SPACING_PX 17
#define WALK_ROUTE_DOT_RADIUS 3
#define WALK_ROUTE_DOT_HALO_RADIUS 5

#ifndef MAPPY_TOUCH_PINCH_SUPPORTED
#define MAPPY_TOUCH_PINCH_SUPPORTED 0
#endif

#define PERSIST_THEME 1
#define PERSIST_TRAVEL_MODE 2
#define PERSIST_BACKLIGHT 3
#define PERSIST_ZOOM 4
#define PERSIST_MAP_ORIENTATION 5
#define PERSIST_UNITS 6
#define PERSIST_TILE_ANIMATION 7
#define TILE_ANIMATION_NONE 0
#define TILE_ANIMATION_FADE 1
#define TILE_ANIMATION_FADE_ZOOM 2
#define TILE_ANIMATION_FADE_MS 480
#define TILE_ANIMATION_FADE_ZOOM_MS 640
#define VISUAL_ANIMATION_TICK_MS 30
#define BEARING_SMOOTHING_MAX_CATCHUP_TICKS 4
#define TILE_ANIMATION_ZOOM_START_Q8 205
#define TILE_REQUEST_STALE_MS 8000
#define TILE_REQUEST_WATCHDOG_MS 1000
#define TILE_REQUEST_MAX_FLIGHTS 2
#define TILE_REQUEST_TOUCH_RESUME_MS 100
#define TILE_REDRAW_COALESCE_MS 60
#define COMPASS_HEADING_FILTER_DEGREES 2
#define GPS_SMOOTHING_NONE 0
#define GPS_SMOOTHING_LOCATION 1
#define GPS_SMOOTHING_MAP 2
#define GPS_SMOOTHING_DEFAULT_INTERVAL_MS 1000
#define GPS_SMOOTHING_MAX_INTERVAL_MS 5000
#define GPS_SMOOTHING_MIN_DURATION_MS 180
#define GPS_SMOOTHING_MAX_DURATION_MS 900
#define GPS_SMOOTHING_DURATION_PER_PX_MS 4
#define TRIG_RATIO_SHIFT 16

#define LOCATION_PUCK_RADIUS 5
#define LOCATION_HALO_RADIUS 8
#define LOCATION_CONE_LENGTH 28
#define LOCATION_CONE_HALF_ANGLE_DEGREES 45
#define LOCATION_BLUE_HEX 0x1A73E8
#define LOCATION_CONE_OUTER_HEX 0xAECBFA
#define LOCATION_CONE_FALLBACK_HEX 0x8AB4F8
#define LOCATION_CONE_BASE_RADIUS 4
#define LOCATION_CONE_OUTER_TIP_RADIUS 4
#define LOCATION_CONE_INNER_TIP_RADIUS 3
#define LOCATION_CONE_OUTLINE_SEGMENTS 8
#define LOCATION_CONE_OUTLINE_HALO_WIDTH 4
#define LOCATION_CONE_OUTLINE_WIDTH 2
#define LOCATION_EDGE_LENGTH_DIVISOR 3
#define LOCATION_EDGE_GAP 3
#define LOCATION_EDGE_INSET \
  (LOCATION_EDGE_GAP + LOCATION_CONE_OUTLINE_HALO_WIDTH / 2)

#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
#define MAPPY_PHONE_MODE_LABEL "fixture"
#define MAPPY_WAITING_TEXT "Loading fixtures"
#else
#define MAPPY_PHONE_MODE_LABEL "phone"
#define MAPPY_WAITING_TEXT "Waiting for phone"
#endif

typedef enum {
  AppStateBooting,
  AppStateWaitingForPhone,
  AppStateSetupRequired,
  AppStateMapLoading,
  AppStateMapReady,
  AppStateRouteLoading,
  AppStateNavigating,
  AppStateRouteError,
} AppState;

typedef struct {
  int32_t world_x;
  int32_t world_y;
  int8_t zoom;
  bool valid;
  bool animation_active;
  uint8_t animation_mode;
  time_t animation_started_s;
  uint16_t animation_started_ms;
  uint32_t last_used;
  TileStorageRef storage;
  uint16_t encoded_length;
  bool storage_suppressed;
} TileCacheEntry;

typedef struct {
  int32_t world_x;
  int32_t world_y;
  int8_t zoom;
} TileRequest;

typedef struct {
  int32_t start_x;
  int32_t end_x;
  int32_t start_y;
  int32_t end_y;
  int8_t zoom;
  bool valid;
} TileCoverageEnvelope;

typedef struct {
  TileRequest request;
  int32_t request_id;
  time_t started_s;
  uint16_t started_ms;
  uint8_t retry_attempt;
  bool active;
  bool discard_only;
} TileFlight;

typedef enum {
  TileApplyIgnored,
  TileApplyIncomplete,
  TileApplyCompletedVisible,
  TileApplyCompletedOffscreen,
  TileApplyDiscarded,
  TileApplyRejected,
} TileApplyResult;

typedef enum {
  TileInvalidateUnknown,
  TileInvalidateTheme,
  TileInvalidateMapSettings,
  TileInvalidateZoom,
} TileInvalidationReason;

typedef struct {
  const char *reason;
} TileSlotDiagnostics;

typedef struct {
  int32_t world_x;
  int32_t world_y;
} RoutePoint;

typedef struct {
  uint8_t slot;
  bool configured;
  uint8_t kind;
  uint8_t default_travel_mode;
  int32_t latitude_e7;
  int32_t longitude_e7;
  char label[DEST_LABEL_BYTES];
} DestinationSlot;

typedef struct {
  uint8_t global_index;
  int32_t start_world_x;
  int32_t start_world_y;
  uint16_t remaining_m;
  uint16_t remaining_s;
  char instruction[MAX_INSTRUCTION_BYTES + 1];
} NavStep;

typedef struct {
  bool valid;
  int32_t progress_px;
  int64_t distance_sq;
  uint16_t segment_index;
  uint32_t segment_t_q16;
} RouteProjection;

typedef struct {
  int32_t viewport_x;
  int32_t viewport_y;
  int32_t center_x;
  int32_t center_y;
  int32_t scale_q8;
  int32_t bearing_centi_degrees;
  int32_t sin_value;
  int32_t cos_value;
} MapRenderTransform;

typedef struct {
  bool pending;
  int category;
  int detail;
  int detail2;
  char text[MAX_INSTRUCTION_BYTES + 1];
} PendingLogEvent;

typedef enum {
  MenuNone,
  MenuDestinations,
  MenuActions,
  MenuTravelMode,
  MenuSettings,
} MenuMode;

typedef enum {
  BearingReacquireNone,
  BearingReacquireRouteStart,
  BearingReacquireWatchLook,
} BearingReacquireReason;

extern Window *s_window;
extern Layer *s_map_layer;
extern TileCacheEntry *s_tiles;
extern uint8_t *s_tile_storage_bytes;
extern uint8_t *s_tile_decode_scratch;
extern TileStorageArena s_tile_storage_arena;
extern int s_tile_cache_size;
extern TileRequest s_request_queue[TILE_CACHE_SIZE];
extern uint8_t s_request_retry_attempts[TILE_CACHE_SIZE];
extern int s_request_count;
extern int s_request_index;
extern int32_t s_inflight_tile_request_id;
extern TileFlight s_tile_flights[TILE_REQUEST_MAX_FLIGHTS];
extern bool s_tile_requests_interaction_paused;
extern bool s_tile_requests_setup_paused;
extern AppTimer *s_tile_request_resume_timer;
extern AppTimer *s_tile_redraw_timer;
extern TileCoverageEnvelope s_request_tile_envelope;
extern TileCoverageEnvelope s_render_tile_envelope;
extern bool s_tile_redraw_deferred;
extern bool s_outbox_busy;
extern int32_t s_outbox_cmd;
extern uint32_t s_access_counter;
extern AppTimer *s_visual_animation_timer;
extern AppTimer *s_tile_request_watchdog_timer;

extern RoutePoint s_route_points[MAX_ROUTE_POINTS];
extern RoutePoint s_route_detail_points[MAX_ROUTE_POINTS];
extern uint16_t s_route_point_count;
extern uint16_t s_route_detail_point_count;
extern int8_t s_route_zoom;
extern int8_t s_route_detail_zoom;
extern int32_t s_route_generation;
extern int32_t s_last_walk_start_feedback_generation;
extern int32_t s_route_detail_generation;
extern int32_t s_route_detail_center_x;
extern int32_t s_route_detail_center_y;
extern int32_t s_route_detail_width;
extern int32_t s_route_detail_height;
extern bool s_route_detail_window_valid;
extern bool s_route_window_request_inflight;
extern bool s_route_window_request_pending;
extern DestinationSlot *s_destinations;
extern uint8_t s_destination_count;
extern NavStep s_nav_steps[MAX_NAV_STEPS];
extern int32_t s_nav_step_progress[MAX_NAV_STEPS];
extern int32_t s_route_total_progress_px;
extern uint8_t s_nav_total_steps;
extern uint8_t s_nav_first_global_index;
extern uint8_t s_nav_step_count;
extern uint8_t s_current_nav_local_index;
extern uint8_t s_next_nav_request_index;
extern int32_t s_last_route_progress;
extern int16_t s_turn_preview_alerted_global_index;
extern int16_t s_turn_now_alerted_global_index;
extern bool s_arrival_dialog_visible;
extern bool s_nav_request_inflight;
extern bool s_route_projection_unavailable_logged;
extern bool s_route_offroute_logged;
extern bool s_route_gps_stale_logged;
extern bool s_route_clear_pending;
extern bool s_route_complete_pending;
extern int32_t s_active_route_request_id;
extern int32_t s_next_request_id;
extern bool s_route_applied_pending;
extern bool s_route_steps_expected;
extern int s_deferred_route_request_slot;
extern PendingLogEvent s_pending_log_events[LOG_EVENT_QUEUE_SIZE];
extern uint8_t s_pending_log_head;
extern uint8_t s_pending_log_count;
extern uint16_t s_pending_log_overflow_count;

extern AppState s_state;
extern GRect s_screen_bounds;
extern int32_t s_viewport_x;
extern int32_t s_viewport_y;
extern int8_t s_viewport_zoom;
extern int32_t s_gps_world_x;
extern int32_t s_gps_world_y;
extern int32_t s_gps_display_world_x;
extern int32_t s_gps_display_world_y;
extern int32_t s_gps_smoothing_start_world_x;
extern int32_t s_gps_smoothing_start_world_y;
extern int32_t s_gps_smoothing_target_world_x;
extern int32_t s_gps_smoothing_target_world_y;
extern int32_t s_render_viewport_x;
extern int32_t s_render_viewport_y;
extern int32_t s_gps_smoothing_start_viewport_x;
extern int32_t s_gps_smoothing_start_viewport_y;
extern int32_t s_gps_smoothing_target_viewport_x;
extern int32_t s_gps_smoothing_target_viewport_y;
extern int8_t s_gps_zoom;
extern int32_t s_heading_degrees;
extern int32_t s_compass_heading_degrees;
extern int32_t s_compass_magnetic_degrees;
extern int32_t s_map_bearing_display_centi_degrees;
extern int32_t s_map_bearing_target_centi_degrees;
extern time_t s_map_bearing_advanced_s;
extern uint16_t s_map_bearing_advanced_ms;
extern bool s_map_bearing_clock_valid;
extern uint32_t s_map_bearing_elapsed_ms;
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
extern bool s_debug_compass_override_active;
#endif
extern int32_t s_declination_centi_degrees;
extern bool s_declination_valid;
extern time_t s_gps_received_at;
extern int32_t s_gps_sequence;
extern int32_t s_gps_elapsed_ms;
extern int32_t s_gps_accuracy_cm;
extern char s_gps_provider[GPS_PROVIDER_BYTES];
extern bool s_has_gps_sequence;
extern bool s_has_gps;
extern bool s_gps_smoothing_active;
extern uint8_t s_gps_smoothing_mode;
extern time_t s_gps_smoothing_started_s;
extern uint16_t s_gps_smoothing_started_ms;
extern uint16_t s_gps_smoothing_duration_ms;
extern bool s_manual_pan;
extern int s_theme_mode;
extern int s_travel_mode;
extern int s_pending_route_mode;
extern int s_active_route_mode;
extern int s_backlight_mode;
extern int s_map_orientation;
extern int s_units_mode;
extern int s_tile_animation_mode;
extern int s_tile_width;
extern int s_tile_height;
extern int s_tile_pixels;
extern int s_tile_bytes;
extern int32_t s_tile_chunk_world_x;
extern int32_t s_tile_chunk_world_y;
extern int8_t s_tile_chunk_zoom;
extern int s_tile_chunk_width;
extern int s_tile_chunk_height;
extern int32_t s_tile_chunk_total;
extern int32_t s_tile_chunk_received;
extern int32_t s_tile_chunk_next_index;
extern int32_t s_tile_chunk_request_id;
extern bool s_tile_chunk_active;
extern bool s_tile_chunk_store_packed;
extern TileRleStreamDecoder s_tile_chunk_decoder;
extern int s_selected_slot;
extern int s_pending_route_slot;
extern int s_active_route_slot;
extern int s_error_category;
extern MenuMode s_menu_mode;
extern int s_menu_selection;
extern bool s_menu_highlight_active;
extern int s_menu_highlight_from_selection;
extern time_t s_menu_highlight_started_s;
extern uint16_t s_menu_highlight_started_ms;
extern GRect s_menu_highlight_from_rect;
extern GRect s_menu_highlight_to_rect;
extern bool s_route_clear_armed;
extern char s_top_text[48];
extern char s_bottom_text[64];
extern char s_instruction[48];
extern int16_t s_transient_zoom_scale_q8;

#ifdef PBL_TOUCH
extern bool s_touch_active;
extern bool s_touch_subscribed;
extern int16_t s_touch_start_x;
extern int16_t s_touch_start_y;
extern int32_t s_touch_start_viewport_x;
extern int32_t s_touch_start_viewport_y;
extern bool s_touch_disabled_logged;
extern bool s_pinch_unavailable_logged;
#endif

extern const GColor s_day_palette[16];
extern const GColor s_night_palette[16];

#if defined(PBL_COMPASS)
int32_t compass_heading_to_degrees(CompassHeading heading);
void update_compass_heading(CompassHeadingData heading_data);
void compass_heading_handler(CompassHeadingData heading_data);
#endif

void write_i32(DictionaryIterator *iter, uint32_t key, int32_t value);
uint16_t read_u16_le(const uint8_t *data, int offset);
int32_t read_i32_le(const uint8_t *data, int offset);
void copy_bounded_text(char *dest, size_t dest_size, const char *src);
void set_bottom_text(const char *text);
void sanitize_payload_text(char *dest, size_t dest_size, const uint8_t *src, uint8_t src_len);
int32_t floor_div_i32(int32_t value, int32_t divisor);
int32_t scale_world_to_zoom(int32_t value, int8_t from_zoom, int8_t to_zoom);
int32_t scale_world_extent_end_to_zoom(int32_t value, int8_t from_zoom,
                                       int8_t to_zoom);
int32_t clamp_i32_to_i16(int32_t value);
int32_t normalize_degrees(int32_t degrees);
bool phone_heading_is_valid(void);
bool gps_fix_fresh_for_seconds(int seconds);
bool phone_heading_is_usable(void);
int32_t normalized_phone_heading_degrees(void);
bool compass_heading_is_valid(void);
bool compass_magnetic_heading_is_valid(void);
int32_t corrected_compass_heading_degrees(int32_t magnetic_degrees);
void refresh_corrected_compass_heading(void);
bool active_facing_heading_degrees(int32_t *heading_degrees);
bool map_orientation_active(void);
void update_map_after_bearing_display_change(bool was_orientation_active);
int32_t render_viewport_x(void);
int32_t render_viewport_y(void);
int32_t display_gps_world_x(void);
int32_t display_gps_world_y(void);
int32_t active_map_bearing_centi_degrees(void);
int32_t active_map_bearing_degrees(void);
int32_t active_map_bearing_angle(void);
void cancel_map_bearing_smoothing(void);
bool sync_map_bearing_smoothing(bool animate);
bool map_bearing_smoothing_active(void);
bool advance_map_bearing_smoothing(void);
bool map_bearing_rendering_visible(void);
void pause_map_bearing_rendering(void);
bool resume_map_bearing_rendering(void);
bool bearing_reacquire_active(void);
void begin_bearing_reacquire(BearingReacquireReason reason);
void arm_route_start_bearing_reacquire(void);
void maybe_begin_pending_route_start_reacquire(void);
void cancel_bearing_reacquire(void);
const char *bearing_reacquire_reason_label(BearingReacquireReason reason);
void refresh_motion_detection_service(void);
void stop_motion_detection_service(void);
bool gps_smoothing_should_animate(bool had_gps, int32_t previous_world_x,
                                  int32_t previous_world_y,
                                  int32_t next_world_x,
                                  int32_t next_world_y,
                                  int32_t previous_elapsed_ms,
                                  int32_t next_elapsed_ms,
                                  time_t previous_received_at,
                                  int32_t *distance_px_out);
void start_gps_smoothing(uint8_t mode, int32_t start_world_x,
                         int32_t start_world_y,
                         int32_t start_viewport_x,
                         int32_t start_viewport_y,
                         int32_t distance_px);
void complete_gps_smoothing(void);
bool gps_smoothing_animation_active(void);
bool advance_gps_smoothing(void);
void world_delta_to_screen_delta(int32_t dx, int32_t dy,
                                        int32_t *screen_dx, int32_t *screen_dy);
void screen_delta_to_world_delta(int32_t screen_dx, int32_t screen_dy,
                                        int32_t *world_dx, int32_t *world_dy);
GPoint screen_point_from_viewport_world(int32_t world_x, int32_t world_y);
int16_t scaled_length(int16_t value);
GPoint point_from_heading(GPoint origin, int32_t heading_degrees, int16_t length);
void start_compass_service(void);
void stop_compass_service(void);
int normalize_tile_animation_mode(int mode);
const char *tile_invalidation_reason_label(TileInvalidationReason reason);
int ceil_div_i32(int value, int divisor);
bool is_supported_tile_geometry(int width, int height);
int active_tile_cache_size(void);
void reset_tile_chunk_assembly(void);
bool configure_tile_geometry(int width, int height);
bool any_pending_tile_requests(void);
int active_tile_flight_count(void);
bool expire_stale_tile_requests(void);
void tile_request_watchdog_callback(void *data);
void schedule_tile_request_watchdog(void);
void cancel_tile_request_watchdog(void);
void invalidate_tiles_with_reason(TileInvalidationReason reason);
bool tile_matches(const TileCacheEntry *entry, int32_t world_x, int32_t world_y, int8_t zoom);
TileCacheEntry *find_tile(int32_t world_x, int32_t world_y, int8_t zoom);
int visible_tile_origins(TileRequest *origins, int max_count);
int request_tile_origins(TileRequest *origins, int max_count);
bool tile_origin_list_contains(const TileRequest *origins, int count,
                               int32_t world_x, int32_t world_y, int8_t zoom);
bool tile_is_visible(const TileCacheEntry *entry);
bool tile_coordinates_visible(int32_t world_x, int32_t world_y, int8_t zoom);
bool tile_coordinates_render_visible(int32_t world_x, int32_t world_y,
                                     int8_t zoom);
void refresh_render_tile_coverage(void);
bool tile_coverage_envelope_contains(const TileCoverageEnvelope *envelope,
                                     int32_t world_x, int32_t world_y,
                                     int8_t zoom);
void clear_offscreen_pending_tile_requests(void);
bool recover_newly_exact_tile_suppression(
    const TileCoverageEnvelope *previous_render_envelope);
void clear_unsent_tile_requests(void);
TileFlight *find_tile_flight(int32_t world_x, int32_t world_y, int8_t zoom,
                            int32_t request_id);
void complete_tile_flight(TileFlight *flight);
void retry_tile_flight(TileFlight *flight, bool retry_immediately);
void handle_tile_request_error(int32_t world_x, int32_t world_y, int8_t zoom,
                               int32_t request_id, bool setup_required,
                               bool retry_immediately);
void handle_tile_request_outbox_failure(AppMessageResult reason);
bool tile_request_is_suppressed(int32_t world_x, int32_t world_y, int8_t zoom);
void suppress_tile_request(int32_t world_x, int32_t world_y, int8_t zoom);
void cancel_all_tile_requests(void);
void pause_tile_requests_for_interaction(void);
void resume_tile_requests_after_interaction(void);
void resume_tile_requests_after_phone_ready(void);
bool tile_requests_paused(void);
void cancel_tile_redraw(void);
void schedule_tile_redraw(bool immediate);
void flush_deferred_tile_redraw(void);
void invalidate_orientation_tile_coverage(void);
bool orientation_tile_coverage_changed(void);
uint16_t tile_animation_duration_ms(uint8_t mode);
uint16_t tile_animation_elapsed_ms(const TileCacheEntry *entry);
uint16_t tile_animation_progress_q8(const TileCacheEntry *entry);
uint16_t tile_animation_eased_q8(uint16_t progress_q8);
void complete_tile_animation(TileCacheEntry *entry);
bool any_tile_animation_active(void);
void complete_tile_animations(void);
bool advance_tile_animations(void);
bool start_tile_animation(TileCacheEntry *entry, bool was_pending);
TileCacheEntry *allocate_tile_slot_with_diagnostics(int32_t world_x, int32_t world_y,
                                                           int8_t zoom,
                                                           TileSlotDiagnostics *diag);
void release_tile_storage(TileCacheEntry *entry);
bool reserve_tile_storage(TileCacheEntry *entry, uint16_t length,
                          TileStorageFormat format);
int valid_visible_tile_count(void);
bool visible_grid_has_missing_tiles(void);
bool visible_grid_is_complete(void);
bool zoom_fallback_active(void);
int8_t zoom_fallback_source_zoom(void);
bool zoom_fallback_retains_entry(const TileCacheEntry *entry);
void zoom_fallback_release_entry(TileCacheEntry *entry);
void clear_zoom_fallback(void);
void begin_zoom_fallback(int8_t previous_zoom);
bool zoom_fallback_entry_fully_covered(const TileCacheEntry *entry);
bool zoom_fallback_entry_covered_by_tile(const TileCacheEntry *entry,
                                         int32_t world_x, int32_t world_y,
                                         int8_t zoom);
void zoom_fallback_maybe_finish(void);
void queue_visible_tiles(void);
void send_next_tile_request(void);
bool decode_cached_tile_row(const TileCacheEntry *entry, int row,
                            uint8_t *packed_row, size_t packed_row_bytes);
TileApplyResult apply_tile(DictionaryIterator *iter);
void apply_theme(DictionaryIterator *iter);
void apply_map_settings(DictionaryIterator *iter);
void apply_map_orientation(DictionaryIterator *iter);
void apply_tile_animation(DictionaryIterator *iter);
void clear_route_detail(void);
bool route_detail_window_covers_viewport(void);
bool route_detail_available_for_draw(void);
void update_state_after_map_change(void);
void clear_route_local(void);
bool maybe_request_route_window(void);
int32_t abs_i32_local(int32_t value);
int32_t saturating_add_i32(int32_t a, int32_t b);
int32_t approx_segment_length_px(int32_t dx, int32_t dy);
int32_t compute_route_total_progress_px(void);
RouteProjection project_route_position(int32_t world_x, int32_t world_y);
RouteProjection project_route_points_position(const RoutePoint *points,
                                              uint16_t point_count,
                                              int32_t world_x,
                                              int32_t world_y);
void recompute_nav_step_progress(void);
int32_t route_progress_threshold_px(uint8_t local_index, int32_t meters,
                                           int32_t fallback_px);
void maybe_request_next_nav_chunk(void);
bool gps_fresh_for_progress(void);
void update_nav_progress_from_gps(void);
bool dismiss_arrival_dialog(void);
void apply_route_clear(void);
void apply_route_points(DictionaryIterator *iter);
void apply_route_window_points(DictionaryIterator *iter);
void apply_nav_steps(DictionaryIterator *iter);
void queue_log_event(int category, int detail, int detail2, const char *text);
bool dequeue_log_event(PendingLogEvent *event);
bool send_log_event(int category, int detail, int detail2, const char *text);
AppMessageResult send_message_begin(DictionaryIterator **iter, int32_t cmd);
void send_init(void);
void cancel_init_retry(void);
void cancel_route_action_retry(void);
void send_route_applied(void);
void send_route_complete(void);
void send_zoom_button(int delta);
void send_route_request(void);
void send_route_clear(void);
bool send_deferred_route_action(void);
void send_theme(void);
void send_travel_mode(void);
void send_units(void);
void send_backlight(void);
void send_map_orientation(void);
void send_tile_animation(void);
void send_nav_steps_request(void);
bool apply_destinations_payload(const uint8_t *data, uint16_t len);
void apply_gps(DictionaryIterator *iter);
void apply_declination(DictionaryIterator *iter);
void apply_debug_compass(DictionaryIterator *iter);
void apply_debug_tile(DictionaryIterator *iter);
void apply_debug_route_progress(DictionaryIterator *iter);
void apply_travel_mode(DictionaryIterator *iter);
bool apply_error(DictionaryIterator *iter);
void inbox_received(DictionaryIterator *iter, void *context);
void inbox_dropped(AppMessageResult reason, void *context);
void outbox_sent(DictionaryIterator *iter, void *context);
void outbox_failed(DictionaryIterator *iter, AppMessageResult reason, void *context);
void recenter_viewport(void);
void update_touch_subscription(void);
bool has_active_route(void);
void open_menu(MenuMode mode);
void close_menu(void);
int menu_item_count(void);
int menu_first_visible_index_for_selection(int selection);
bool menu_row_rect_for_index_at_first(int item_index, int first, GRect *rect_out);
void cancel_menu_highlight_animation(void);
void reset_menu_highlight_animation(void);
void start_menu_highlight_animation(int previous_selection, int direction);
void start_menu_value_animation(int direction);
bool menu_highlight_animation_active(void);
bool advance_menu_highlight_animation(void);
bool menu_highlight_rect(GRect *rect_out);
int menu_highlight_text_index(GRect highlight_rect, int first);
const char *travel_mode_label(int mode);
const char *theme_label(int mode);
const char *orientation_label(void);
const char *tile_animation_label(void);
const char *menu_title(void);
void menu_item_label(int index, char *buffer, size_t buffer_size);
void select_menu_item(void);
bool set_viewport_zoom(int next_zoom, int notification_delta);
void zoom_to_max_map_level(void);
void change_zoom(int delta);
void up_click_handler(ClickRecognizerRef recognizer, void *context);
void down_click_handler(ClickRecognizerRef recognizer, void *context);
void select_click_handler(ClickRecognizerRef recognizer, void *context);
void back_click_handler(ClickRecognizerRef recognizer, void *context);
void click_config_provider(void *context);
GColor chrome_bg(void);
GColor chrome_fg(void);
GColor chrome_border(void);
GColor chrome_accent(void);
uint8_t tile_fade_order(int px, int py);
void draw_tile_placeholders(GContext *ctx);
bool tile_animation_draws_pixel(int px, int py, uint16_t progress_q8);
int32_t tile_zoomed_local_coord_q8(int local_px, int tile_pixels, uint16_t scale_q8);
bool draw_tiles_framebuffer_fast(GContext *ctx, const GColor *palette,
                                 TileCacheEntry **entries, int entry_count,
                                 uint8_t background_argb);
void draw_tile_entry_slow(GContext *ctx, TileCacheEntry *entry,
                          const GColor *palette);
void draw_tiles(GContext *ctx, GColor background, bool fill_background);
void draw_route(GContext *ctx, const MapRenderTransform *transform);
void draw_destination_marker(GContext *ctx, const MapRenderTransform *transform);
void draw_current_location_cone(GContext *ctx, GPoint point, int32_t display_heading);
void draw_current_location(GContext *ctx, const MapRenderTransform *transform);
void draw_card(GContext *ctx, GRect rect, GColor fill, GColor border);
void draw_text_in_rect(GContext *ctx, GRect rect, const char *text, GFont font,
                              GColor color, GTextAlignment alignment);
void copy_text_span(char *dest, size_t dest_size, const char *start, size_t len);
void split_status_text(const char *source, char *primary, size_t primary_size,
                              char *secondary, size_t secondary_size);
void draw_top_chrome(GContext *ctx);
void draw_compact_status(GContext *ctx);
void draw_route_status(GContext *ctx);
void draw_status_chrome(GContext *ctx);
void draw_arrival_dialog(GContext *ctx);
void draw_menu(GContext *ctx);
void map_layer_update(Layer *layer, GContext *ctx);
bool visual_animations_active(void);
void schedule_visual_animation_tick(void);
void release_visual_animation_tick_if_idle(void);
void cancel_visual_animation_timer(void);
bool pan_inertia_animation_active(void);
bool advance_pan_inertia_animation(void);
void settle_pan_motion(void);
void cancel_pan_motion_for_teardown(void);
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
void fixture_perf_begin(void);
void fixture_perf_bearing_immediate_step(void);
void fixture_perf_scheduler_tick(bool bearing_active, bool gps_active,
                                 bool tile_active, bool menu_active,
                                 bool inertia_active, bool bearing_changed,
                                 bool inertia_changed);
void fixture_perf_map_draw(void);
void fixture_perf_map_draw_complete(void);
void fixture_perf_rotated_render(uint32_t destination_pixels,
                                 uint32_t sample_attempts,
                                 uint32_t packed_hits,
                                 uint32_t rle_hits,
                                 uint32_t rle_misses,
                                 uint32_t rle_decoded_pixels,
                                 uint32_t passes,
                                 uint32_t cardinal_passes,
                                 uint32_t dda_passes,
                                 uint32_t scaled_passes,
                                 uint32_t decode_errors);
void fixture_perf_route_projection_recompute(void);
void fixture_perf_orientation_work(void);
void fixture_perf_route_segment(bool submitted);
void fixture_perf_start_mixed_sources(void);
void fixture_perf_enter_manual_browse(void);
void fixture_set_location_screen_position(int32_t screen_x, int32_t screen_y);
void fixture_perf_pan_under_load(int action);
bool fixture_start_pan_inertia(int32_t viewport_dx, int32_t viewport_dy,
                               uint16_t elapsed_ms);
void fixture_perf_maybe_emit(void);
#endif
#ifdef MAPPY_WATCH_HARDWARE_PERF
void hardware_perf_begin_zoom(void);
void hardware_perf_begin_pan(void);
void hardware_perf_note_pan_input(time_t seconds, uint16_t milliseconds);
void hardware_perf_pan_release(bool inertia_started);
void hardware_perf_pan_settled(uint8_t ticks, bool cancelled);
void hardware_perf_flush_pan(void);
void hardware_perf_map_draw_begin(void);
void hardware_perf_map_draw_complete(void);
#endif
void window_load(Window *window);
void window_unload(Window *window);
void load_settings(void);
void init(void);
void deinit(void);

#ifdef PBL_TOUCH
void reset_touch_state(void);
void log_touch_disabled_once(void);
void log_pinch_unavailable_once(void);
void begin_pan_interaction(int16_t screen_x, int16_t screen_y);
void update_pan_interaction(int16_t screen_x, int16_t screen_y);
void end_pan_interaction(int16_t screen_x, int16_t screen_y);
void touch_handler(const TouchEvent *event, void *context);
#endif

#endif
