// Exercise the actual shared scheduler with a deterministic clock and timer.
#define MAPPY_H
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#define VISUAL_ANIMATION_TICK_MS 30
#define TILE_ANIMATION_TICK_MS 40
typedef struct { bool armed; } AppTimer;
static AppTimer timer;
AppTimer *s_visual_animation_timer;
void *s_map_layer = &timer;
static uint32_t now_ms, requested_delay, callback_work_ms;
static unsigned sources, redraws, registrations;
static bool fail_registration;
static void (*pending_callback)(void *);
enum { Bearing = 1, Gps = 2, Tile = 4, Menu = 8, Inertia = 16 };

static uint16_t time_ms(time_t *seconds, uint16_t *milliseconds) {
  if (seconds) *seconds = now_ms / 1000;
  if (milliseconds) *milliseconds = now_ms % 1000;
  return now_ms % 1000;
}
static AppTimer *app_timer_register(uint32_t delay, void (*callback)(void *), void *data) {
  (void)data;
  assert(!timer.armed);
  registrations++;
  requested_delay = delay;
  pending_callback = callback;
  if (fail_registration) return NULL;
  timer.armed = true;
  return &timer;
}
static void app_timer_cancel(AppTimer *value) { assert(value == &timer); timer.armed = false; }
static void layer_mark_dirty(void *layer) { assert(layer == s_map_layer); redraws++; }
static bool map_bearing_smoothing_active(void) { return (sources & Bearing) != 0; }
static bool gps_smoothing_animation_active(void) { return (sources & Gps) != 0; }
static bool any_tile_animation_active(void) { return (sources & Tile) != 0; }
static bool menu_highlight_animation_active(void) { return (sources & Menu) != 0; }
static bool pan_inertia_animation_active(void) { return (sources & Inertia) != 0; }
static bool advance_map_bearing_smoothing(void) { now_ms += callback_work_ms; return map_bearing_smoothing_active(); }
static bool advance_gps_smoothing(void) { return gps_smoothing_animation_active(); }
static bool advance_tile_animations(void) { return any_tile_animation_active(); }
static bool advance_menu_highlight_animation(void) { return menu_highlight_animation_active(); }
static bool advance_pan_inertia_animation(void) { return pan_inertia_animation_active(); }
static void complete_tile_animations(void) { sources &= ~Tile; }
static void complete_gps_smoothing(void) { sources &= ~Gps; }
static void cancel_menu_highlight_animation(void) { sources &= ~Menu; }
static void resume_map_bearing_rendering(void) { sources &= ~Bearing; }
static void settle_pan_motion(void) { sources &= ~Inertia; }
void schedule_visual_animation_tick(void);
#include "../apps/pebble-watch/src/c/animation_scheduler.c"

static void reset(uint32_t start, unsigned active) {
  cancel_visual_animation_timer();
  now_ms = start;
  sources = active;
  callback_work_ms = redraws = registrations = 0;
  fail_registration = false;
}
static void fire(uint32_t late_ms) {
  assert(timer.armed);
  now_ms += requested_delay + late_ms;
  timer.armed = false;
  pending_callback(NULL);
}
int main(void) {
  reset(1000, Bearing);
  schedule_visual_animation_tick();
  assert(requested_delay == 30);
  schedule_visual_animation_tick();
  assert(registrations == 1); // All sources share one pending frame.
  callback_work_ms = 7;
  for (unsigned frame = 0; frame < 20; ++frame) {
    fire(4);
    assert(now_ms == 1041 + frame * 30);
    assert(requested_delay == 19); // 4 ms dispatch + 7 ms update do not accumulate.
  }
  assert(redraws == 20);
  fire(95);
  assert(requested_delay == 18); // Skip missed slots; never replay a burst.
  sources = 0;
  fire(0);
  assert(!timer.armed && !s_visual_animation_timer);
  now_ms += 10000;
  sources = Bearing;
  schedule_visual_animation_tick();
  assert(requested_delay == 30); // Idle time cannot leak into a new animation.

  reset(0, Tile);
  schedule_visual_animation_tick();
  assert(requested_delay == 40);
  sources |= Bearing;
  fire(0);
  assert(requested_delay == 30);
  sources = Tile;
  fire(0);
  assert(requested_delay == 40);
  sources = 0;
  release_visual_animation_tick_if_idle();
  assert(!timer.armed);

  reset(120000, Bearing);
  schedule_visual_animation_tick();
  now_ms -= 60000;
  fire(0);
  assert(requested_delay == 30); // Clock correction cannot strand animations.

  reset(UINT32_MAX - 10u, Bearing);
  schedule_visual_animation_tick();
  fire(4);
  assert(now_ms == 23 && requested_delay == 26); // Millisecond counter wrap.
  fire(60);
  assert(requested_delay == 30); // Exactly expired slot moves to the next one.

  reset(0, Bearing | Gps | Tile | Menu | Inertia);
  fail_registration = true;
  schedule_visual_animation_tick();
  assert(!visual_animations_active() && !s_visual_animation_timer);
  assert(redraws == 1); // Failed registration settles every visual source.
  fail_registration = false;
  now_ms = 1000;
  sources = Bearing;
  schedule_visual_animation_tick();
  assert(requested_delay == 30);
  puts("Animation scheduler: drift, late frames, coalescing, cadence changes, wrap and recovery passed");
  return 0;
}
