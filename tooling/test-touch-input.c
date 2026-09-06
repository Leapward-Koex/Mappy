#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#include <time.h>
#include "pan_inertia.h"

// Compile the production recenter/touch section with deterministic platform
// services. Menu and button rendering are outside this input regression.
#define MAPPY_H
#define PBL_TOUCH
#define MAPPY_TOUCH_PINCH_SUPPORTED 0
#define TRANSIENT_SCALE_Q8_ONE 256
#define MenuNone 0

typedef struct { int unused; } Layer;
typedef struct { int unused; } AppTimer;
typedef enum {
  TouchEvent_Touchdown, TouchEvent_Liftoff, TouchEvent_PositionUpdate
} TouchEventType;
typedef struct { TouchEventType type; int16_t x, y; } TouchEvent;

static Layer test_layer;
static AppTimer test_timer;
static uint32_t now_ms;
static bool touch_enabled;
static int dirty_count, queue_count, resume_count, tile_completion_count;
static int s_menu_mode, s_map_orientation;
static bool s_has_gps, s_manual_pan, s_arrival_dialog_visible;
static bool s_touch_active, s_touch_subscribed;
static bool s_touch_disabled_logged, s_pinch_unavailable_logged;
static bool s_tile_requests_interaction_paused;
static int16_t s_touch_start_x, s_touch_start_y;
static int32_t s_touch_start_viewport_x, s_touch_start_viewport_y;
static int32_t s_viewport_x, s_viewport_y, s_gps_world_x, s_gps_world_y;
static int8_t s_viewport_zoom, s_gps_zoom;
static int s_transient_zoom_scale_q8;
static Layer *s_map_layer;
static AppTimer *s_visual_animation_timer, *s_tile_request_resume_timer;

void settle_pan_motion(void);
bool pan_inertia_animation_active(void);
static void layer_mark_dirty(Layer *layer) { assert(layer); dirty_count++; }
static void set_bottom_text(const char *text) { (void)text; }
static void complete_gps_smoothing(void) {}
static bool map_orientation_active(void) {
  return s_map_orientation == 1 && !s_manual_pan;
}
static int32_t scale_world_to_zoom(int32_t value, int8_t from, int8_t to) {
  assert(from == to);
  return value;
}
static void reset_map_bearing_display_to_north(void) {}
static void sync_map_bearing_smoothing(bool animate) { (void)animate; }
static void update_state_after_map_change(void) {}
static void queue_visible_tiles(void) { queue_count++; }
static void refresh_motion_detection_service(void) {}
static uint16_t time_ms(time_t *seconds, uint16_t *milliseconds) {
  if (seconds) *seconds = now_ms / 1000;
  if (milliseconds) *milliseconds = now_ms % 1000;
  return now_ms % 1000;
}
static void send_log_event(int a, int b, int c, const char *text) {
  (void)a; (void)b; (void)c; (void)text;
}
static void screen_delta_to_world_delta(int16_t dx, int16_t dy,
                                         int32_t *wx, int32_t *wy) {
  // The accepted drag must switch out of face forward before projection.
  assert(!map_orientation_active());
  *wx = dx; *wy = dy;
}
static void resume_tile_requests_after_interaction(void) {
  resume_count++;
  s_tile_requests_interaction_paused = false;
}
static void pause_tile_requests_for_interaction(void) {
  s_tile_requests_interaction_paused = true;
}
static void complete_tile_animations(void) { tile_completion_count++; }
static void release_visual_animation_tick_if_idle(void) {
  if (!pan_inertia_animation_active()) s_visual_animation_timer = NULL;
}
static void schedule_visual_animation_tick(void) {
  s_visual_animation_timer = &test_timer;
}
static void app_timer_cancel(AppTimer *timer) { (void)timer; }
static bool touch_service_is_enabled(void) { return touch_enabled; }
static void touch_service_unsubscribe(void) {}
static void touch_service_subscribe(void (*handler)(const TouchEvent *, void *),
                                     void *context) {
  (void)handler; (void)context;
}

#include "touch-input-under-test.h"

static void reset_input(void) {
  cancel_pan_motion_for_teardown();
  s_touch_teardown = s_touch_requires_touchdown = false;
  s_visual_animation_timer = NULL;
  s_tile_requests_interaction_paused = false;
  s_map_layer = &test_layer;
  s_menu_mode = MenuNone;
  s_arrival_dialog_visible = false;
  s_has_gps = touch_enabled = s_touch_subscribed = true;
  s_manual_pan = false;
  s_map_orientation = 1;
  s_viewport_zoom = s_gps_zoom = 15;
  s_viewport_x = s_gps_world_x = 1000;
  s_viewport_y = s_gps_world_y = 2000;
  now_ms = 100000;
  dirty_count = queue_count = resume_count = tile_completion_count = 0;
}

static void touch(TouchEventType type, int16_t x, int16_t y) {
  now_ms += 30;
  TouchEvent event = {.type = type, .x = x, .y = y};
  touch_handler(&event, NULL);
}

static void test_missing_touchdown(void) {
  for (int orientation = 0; orientation <= 1; orientation++) {
    reset_input();
    s_map_orientation = orientation;
    touch(TouchEvent_PositionUpdate, 60, 70);
    assert(s_touch_active && s_manual_pan && !map_orientation_active());
    assert(s_viewport_x == 1000 && s_viewport_y == 2000);
    assert(dirty_count == 1 && tile_completion_count == 1);
    assert(s_tile_requests_interaction_paused && queue_count == 0);
    touch(TouchEvent_PositionUpdate, 90, 80);
    assert(s_viewport_x == 970 && s_viewport_y == 1990);
    assert(tile_completion_count == 1 && resume_count == 0);
    // The release may contain the only remaining movement after queue loss.
    touch(TouchEvent_Liftoff, 100, 90);
    assert(s_viewport_x == 960 && s_viewport_y == 1980);
    assert(!s_touch_active && s_manual_pan);
    settle_pan_motion();
    assert(!s_tile_requests_interaction_paused && resume_count == 1);
    recenter_viewport();
    assert(!s_manual_pan && map_orientation_active() == (orientation == 1));
    assert(s_viewport_x == 1000 && s_viewport_y == 2000);
    assert(s_map_orientation == orientation);
  }
}

static void test_normal_and_sparse_gestures(void) {
  reset_input();
  touch(TouchEvent_Touchdown, 60, 70);
  touch(TouchEvent_PositionUpdate, 90, 80);
  touch(TouchEvent_PositionUpdate, 100, 90);
  assert(s_viewport_x == 960 && s_viewport_y == 1980);
  assert(tile_completion_count == 1);
  touch(TouchEvent_Liftoff, 105, 95);
  assert(s_viewport_x == 955 && s_viewport_y == 1975);
  reset_input();
  touch(TouchEvent_Touchdown, 60, 70);
  touch(TouchEvent_Liftoff, 100, 90);
  assert(s_viewport_x == 960 && s_viewport_y == 1980);
  reset_input();
  touch(TouchEvent_Liftoff, 100, 90);
  assert(!s_touch_active && !s_manual_pan && dirty_count == 0);
}

static void test_cancelled_gesture_does_not_restart(void) {
  reset_input();
  touch(TouchEvent_Touchdown, 60, 70);
  touch(TouchEvent_PositionUpdate, 90, 80);
  recenter_viewport();
  touch(TouchEvent_PositionUpdate, 100, 90);
  assert(!s_touch_active && map_orientation_active());
  assert(s_viewport_x == 1000 && s_viewport_y == 2000);
  touch(TouchEvent_Liftoff, 100, 90);
  touch(TouchEvent_PositionUpdate, 60, 70);
  assert(s_touch_active && s_manual_pan);
  // A fresh touchdown must also recover when the cancelled liftoff was lost.
  recenter_viewport();
  touch(TouchEvent_Touchdown, 60, 70);
  touch(TouchEvent_PositionUpdate, 90, 80);
  assert(s_viewport_x == 970 && s_viewport_y == 1990);
}

static void test_input_ownership(void) {
  for (int gate = 0; gate < 6; gate++) {
    reset_input();
    if (gate == 0) s_menu_mode = 1;
    if (gate == 1) s_arrival_dialog_visible = true;
    if (gate == 2) touch_enabled = false;
    if (gate == 3) { s_has_gps = false; update_touch_subscription(); }
    if (gate == 4) s_touch_subscribed = false;
    if (gate == 5) cancel_pan_motion_for_teardown();
    touch(TouchEvent_PositionUpdate, 60, 70);
    assert(!s_touch_active && !s_manual_pan && dirty_count == 0);
  }
  reset_input();
  touch(TouchEvent_Touchdown, 60, 70);
  s_menu_mode = 1;
  update_touch_subscription();
  s_menu_mode = MenuNone;
  update_touch_subscription();
  touch(TouchEvent_PositionUpdate, 90, 80);
  assert(!s_touch_active && s_viewport_x == 1000);
  touch(TouchEvent_Touchdown, 60, 70);
  touch(TouchEvent_PositionUpdate, 90, 80);
  assert(s_touch_active && s_viewport_x == 970);
  touch_handler(NULL, NULL);
}

int main(void) {
  test_missing_touchdown();
  test_normal_and_sparse_gestures();
  test_cancelled_gesture_does_not_restart();
  test_input_ownership();
  puts("Touch input recovery and lifecycle tests passed.");
  return 0;
}
