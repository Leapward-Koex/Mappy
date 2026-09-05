// Minimal Pebble/state surface for compiling the actual map_geometry.c on host.
#ifndef MAPPY_BEARING_INTEGRATION_SHIM_H
#define MAPPY_BEARING_INTEGRATION_SHIM_H
#define MAPPY_H
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <limits.h>
#include <string.h>
#include <time.h>
#include "../apps/pebble-watch/src/c/bearing_smoothing.h"
#ifndef MAPPY_TEST_PHONE_HEADING
#define PBL_COMPASS 1
#endif
#define TRIG_MAX_ANGLE 65536
#define TRIG_MAX_RATIO 65536
#define TRIG_RATIO_SHIFT 16
#define HEADING_FRESH_SECONDS 30
#define GPS_SMOOTHING_DEFAULT_INTERVAL_MS 1000
#define GPS_SMOOTHING_MAX_INTERVAL_MS 5000
#define GPS_SMOOTHING_MIN_DURATION_MS 180
#define GPS_SMOOTHING_MAX_DURATION_MS 900
#define GPS_SMOOTHING_DURATION_PER_PX_MS 4
#define GPS_SMOOTHING_NONE 0
#define GPS_SMOOTHING_LOCATION 1
#define GPS_SMOOTHING_MAP 2
#define TRAVEL_MODE_WALK 0
#define TRAVEL_MODE_BIKE 1
#define TRAVEL_MODE_DRIVE 2
#define TRANSIENT_SCALE_Q8_ONE 256
#define MenuNone 0

typedef struct { int16_t x, y; } GPoint;
typedef struct { int16_t w, h; } GSize;
typedef struct { GPoint origin; GSize size; } GRect;
#define GPoint(x_, y_) ((GPoint){(x_), (y_)})
typedef int32_t CompassHeading;
typedef enum { CompassStatusUnavailable = -1, CompassStatusDataInvalid,
  CompassStatusCalibrating, CompassStatusCalibrated } CompassStatus;
typedef struct { CompassHeading magnetic_heading, true_heading;
  CompassStatus compass_status; bool is_declination_valid; } CompassHeadingData;

static uint32_t test_now_ms;
static unsigned test_dirty, test_coverage, test_queue;
static bool test_scheduled, test_subscribed, test_filter_after_subscribe;
static int32_t test_filter;
static int s_menu_mode, s_map_orientation, s_active_route_mode, s_travel_mode;
static bool s_arrival_dialog_visible, s_manual_pan, s_has_gps, s_declination_valid;
static int32_t s_heading_degrees, s_compass_heading_degrees;
static int32_t s_compass_magnetic_degrees, s_compass_heading_centi_degrees;
static int32_t s_compass_magnetic_centi_degrees, s_declination_centi_degrees;
static int32_t s_map_bearing_display_centi_degrees, s_map_bearing_target_centi_degrees;
static void *s_map_layer = (void *)1;
static GRect s_screen_bounds = {{0, 0}, {200, 228}};
static int32_t s_viewport_x, s_viewport_y, s_render_viewport_x, s_render_viewport_y;
static int32_t s_gps_world_x, s_gps_world_y, s_gps_display_world_x, s_gps_display_world_y;
static int32_t s_gps_smoothing_start_world_x, s_gps_smoothing_start_world_y;
static int32_t s_gps_smoothing_target_world_x, s_gps_smoothing_target_world_y;
static int32_t s_gps_smoothing_start_viewport_x, s_gps_smoothing_start_viewport_y;
static int32_t s_gps_smoothing_target_viewport_x, s_gps_smoothing_target_viewport_y;
static int32_t s_transient_zoom_scale_q8 = 256;
static bool s_gps_smoothing_active;
static uint8_t s_gps_smoothing_mode;
static uint16_t s_gps_smoothing_duration_ms, s_gps_smoothing_started_ms;
static time_t s_gps_smoothing_started_s, s_gps_received_at;

static void time_ms(time_t *seconds, uint16_t *milliseconds) {
  *seconds = test_now_ms / 1000; *milliseconds = test_now_ms % 1000;
}
static time_t integration_time(time_t *output) {
  time_t now = test_now_ms / 1000; if (output) *output = now; return now;
}
#define time integration_time
bool map_orientation_active(void);
bool map_bearing_smoothing_active(void);
bool compass_heading_is_valid(void);
bool compass_magnetic_heading_is_valid(void);
bool phone_heading_is_usable(void);
int32_t normalized_phone_heading_degrees(void);
int32_t active_map_bearing_centi_degrees(void);
static void invalidate_orientation_tile_coverage(void) { test_coverage++; }
static bool orientation_tile_coverage_changed(void) { test_coverage++; return true; }
static void update_state_after_map_change(void) {}
static void queue_visible_tiles(void) { test_queue++; }
static void layer_mark_dirty(void *layer) { (void)layer; test_dirty++; }
static bool has_active_route(void) { return false; }
static uint16_t tile_animation_eased_q8(uint16_t progress) { return progress; }
static void schedule_visual_animation_tick(void) {
  if (map_bearing_smoothing_active()) test_scheduled = true;
}
static void release_visual_animation_tick_if_idle(void) {
  if (!map_bearing_smoothing_active()) test_scheduled = false;
}
static void maybe_begin_pending_route_start_reacquire(void) {}
static int32_t sin_lookup(int32_t angle) { (void)angle; return 0; }
static int32_t cos_lookup(int32_t angle) { (void)angle; return TRIG_MAX_RATIO; }
#ifdef PBL_COMPASS
static void compass_service_subscribe(void (*callback)(CompassHeadingData)) {
  (void)callback; test_subscribed = true;
}
static void compass_service_set_heading_filter(int32_t filter) {
  test_filter_after_subscribe = test_subscribed; test_filter = filter;
}
static void compass_service_unsubscribe(void) { test_subscribed = false; }
#endif
#endif
