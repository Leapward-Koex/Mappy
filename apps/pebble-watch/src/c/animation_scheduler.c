#include "mappy.h"

// One cadence and one redraw for all visual animation sources.

static uint32_t visual_animation_tick_ms(void) {
  // Tile reveals tolerate the specification's 20-30 fps target. Keep the
  // existing cadence whenever an interaction or position animation shares the
  // scheduler, but give tile-only frames more event-loop headroom.
  bool non_tile_active = map_bearing_smoothing_active() ||
      gps_smoothing_animation_active() || menu_highlight_animation_active() ||
      pan_inertia_animation_active();
  // The caller has already established that some visual source is active, so
  // no non-tile source necessarily means this is a tile-only tick.
  return non_tile_active ? VISUAL_ANIMATION_TICK_MS : TILE_ANIMATION_TICK_MS;
}

bool visual_animations_active(void) {
  return map_bearing_smoothing_active() || gps_smoothing_animation_active() ||
      any_tile_animation_active() || menu_highlight_animation_active() ||
      pan_inertia_animation_active();
}

void cancel_visual_animation_timer(void) {
  if (s_visual_animation_timer) {
    app_timer_cancel(s_visual_animation_timer);
    s_visual_animation_timer = NULL;
  }
}

static void visual_animation_timer_callback(void *data) {
  (void)data;
  s_visual_animation_timer = NULL;

#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  bool bearing_active = map_bearing_smoothing_active();
  bool gps_active = gps_smoothing_animation_active();
  bool tile_active = any_tile_animation_active();
  bool menu_active = menu_highlight_animation_active();
  bool inertia_active = pan_inertia_animation_active();
#endif
  bool bearing_changed = advance_map_bearing_smoothing();
  bool changed = bearing_changed;
  changed = advance_gps_smoothing() || changed;
  bool inertia_changed = advance_pan_inertia_animation();
  changed = inertia_changed || changed;
  changed = advance_tile_animations() || changed;
  changed = advance_menu_highlight_animation() || changed;
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  fixture_perf_scheduler_tick(bearing_active, gps_active, tile_active,
                              menu_active, inertia_active, bearing_changed,
                              inertia_changed);
#endif

  if (visual_animations_active()) {
    schedule_visual_animation_tick();
  }
  if (changed && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  // Let a no-op tick close fixture measurements for sources that settled
  // between scheduling and callback dispatch.
  if (!changed) {
    fixture_perf_maybe_emit();
  }
#endif
}

void schedule_visual_animation_tick(void) {
  if (!s_visual_animation_timer && visual_animations_active()) {
    s_visual_animation_timer = app_timer_register(
        visual_animation_tick_ms(), visual_animation_timer_callback, NULL);
    if (!s_visual_animation_timer) {
      // A failed re-arm must not strand partially rendered state indefinitely.
      // Settle every source synchronously and coalesce one final redraw.
      complete_tile_animations();
      complete_gps_smoothing();
      cancel_menu_highlight_animation();
      if (map_bearing_smoothing_active()) {
        // Snap to the requested target and refresh bearing-dependent coverage;
        // cancel_map_bearing_smoothing() would instead freeze mid-transition.
        resume_map_bearing_rendering();
      }
      if (pan_inertia_animation_active()) {
        settle_pan_motion();
      }
      if (s_map_layer) {
        layer_mark_dirty(s_map_layer);
      }
    }
  }
}

void release_visual_animation_tick_if_idle(void) {
  if (!visual_animations_active()) {
    cancel_visual_animation_timer();
  }
}
