#include "mappy.h"

// One cadence and one redraw for all visual animation sources.

bool visual_animations_active(void) {
  return map_bearing_smoothing_active() || gps_smoothing_animation_active() ||
      any_tile_animation_active() || menu_highlight_animation_active();
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
#endif
  bool bearing_changed = advance_map_bearing_smoothing();
  bool changed = bearing_changed;
  changed = advance_gps_smoothing() || changed;
  changed = advance_tile_animations() || changed;
  changed = advance_menu_highlight_animation() || changed;
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  fixture_perf_scheduler_tick(bearing_active, gps_active, tile_active,
                              menu_active, bearing_changed);
#endif

  if (visual_animations_active()) {
    schedule_visual_animation_tick();
  }
  if (changed && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  // A render can complete the final animation while a sentinel timer is
  // already queued. Let that timer close a fixture measurement even though it
  // has no additional frame to dirty.
  if (!changed) {
    fixture_perf_maybe_emit();
  }
#endif
}

void schedule_visual_animation_tick(void) {
  if (!s_visual_animation_timer && visual_animations_active()) {
    s_visual_animation_timer = app_timer_register(
        VISUAL_ANIMATION_TICK_MS, visual_animation_timer_callback, NULL);
  }
}

void release_visual_animation_tick_if_idle(void) {
  if (!visual_animations_active()) {
    cancel_visual_animation_timer();
  }
}
