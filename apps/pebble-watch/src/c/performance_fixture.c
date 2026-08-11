#include "mappy.h"

#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE

typedef struct {
  uint32_t scheduler_ticks;
  uint32_t map_draws;
  uint32_t bearing_steps;
  uint32_t bearing_advances;
  uint32_t gps_advances;
  uint32_t tile_advances;
  uint32_t menu_advances;
  uint32_t multi_source_ticks;
  uint32_t manual_browse_bearing_ticks;
  uint32_t manual_browse_map_errors;
  uint32_t route_projection_recomputes;
  uint32_t orientation_work;
  uint32_t route_segments_submitted;
  uint32_t route_segments_clipped;
  uint32_t map_draw_time_ms;
  uint32_t max_map_draw_time_ms;
  uint32_t errors;
} FixturePerfCounters;

static FixturePerfCounters s_fixture_perf;
static uint32_t s_fixture_perf_session_id;
static bool s_fixture_perf_active;
static time_t s_fixture_perf_draw_started_s;
static uint16_t s_fixture_perf_draw_started_ms;

void fixture_perf_begin(void) {
  memset(&s_fixture_perf, 0, sizeof(s_fixture_perf));
  s_fixture_perf_session_id++;
  s_fixture_perf_active = true;
}

void fixture_perf_bearing_immediate_step(void) {
  if (s_fixture_perf_active) {
    s_fixture_perf.bearing_steps++;
  }
}

void fixture_perf_scheduler_tick(bool bearing_active, bool gps_active,
                                 bool tile_active, bool menu_active,
                                 bool bearing_changed) {
  if (!s_fixture_perf_active) {
    return;
  }
  s_fixture_perf.scheduler_ticks++;
  uint8_t active_sources = 0;
  if (bearing_active) {
    s_fixture_perf.bearing_advances++;
    active_sources++;
    if (s_manual_pan) {
      s_fixture_perf.manual_browse_bearing_ticks++;
      if (map_orientation_active() || active_map_bearing_centi_degrees() != 0) {
        s_fixture_perf.manual_browse_map_errors++;
        s_fixture_perf.errors++;
      }
    }
  }
  if (gps_active) {
    s_fixture_perf.gps_advances++;
    active_sources++;
  }
  if (tile_active) {
    s_fixture_perf.tile_advances++;
    active_sources++;
  }
  if (menu_active) {
    s_fixture_perf.menu_advances++;
    active_sources++;
  }
  if (bearing_changed) {
    s_fixture_perf.bearing_steps++;
  }
  if (active_sources > 1) {
    s_fixture_perf.multi_source_ticks++;
  }
}

void fixture_perf_map_draw(void) {
  if (s_fixture_perf_active) {
    s_fixture_perf.map_draws++;
    time_ms(&s_fixture_perf_draw_started_s, &s_fixture_perf_draw_started_ms);
  }
}

void fixture_perf_map_draw_complete(void) {
  if (!s_fixture_perf_active) {
    return;
  }
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  int32_t elapsed = (int32_t)(now_s - s_fixture_perf_draw_started_s) * 1000 +
      (int32_t)now_ms - (int32_t)s_fixture_perf_draw_started_ms;
  if (elapsed < 0) {
    s_fixture_perf.errors++;
    return;
  }
  s_fixture_perf.map_draw_time_ms += (uint32_t)elapsed;
  if ((uint32_t)elapsed > s_fixture_perf.max_map_draw_time_ms) {
    s_fixture_perf.max_map_draw_time_ms = (uint32_t)elapsed;
  }
}

void fixture_perf_route_projection_recompute(void) {
  if (s_fixture_perf_active) {
    s_fixture_perf.route_projection_recomputes++;
  }
}

void fixture_perf_orientation_work(void) {
  if (s_fixture_perf_active) {
    s_fixture_perf.orientation_work++;
  }
}

void fixture_perf_route_segment(bool submitted) {
  if (!s_fixture_perf_active) {
    return;
  }
  if (submitted) {
    s_fixture_perf.route_segments_submitted++;
  } else {
    s_fixture_perf.route_segments_clipped++;
  }
}

void fixture_perf_start_mixed_sources(void) {
  if (s_has_gps) {
    start_gps_smoothing(GPS_SMOOTHING_LOCATION,
                        display_gps_world_x() - 48,
                        display_gps_world_y() + 24,
                        render_viewport_x(), render_viewport_y(), 54);
  }
  if (s_tiles) {
    int capacity = active_tile_cache_size();
    for (int i = 0; i < capacity; i++) {
      if (s_tiles[i].valid && tile_is_visible(&s_tiles[i])) {
        start_tile_animation(&s_tiles[i], true);
        break;
      }
    }
  }
  s_menu_mode = MenuSettings;
  s_menu_selection = 1;
  start_menu_highlight_animation(0, 1);
}

void fixture_perf_enter_manual_browse(void) {
  complete_tile_animations();
  complete_gps_smoothing();
  cancel_menu_highlight_animation();
  s_menu_mode = MenuNone;
  s_menu_selection = 0;
  s_manual_pan = true;
  sync_map_bearing_smoothing(false);
  update_state_after_map_change();
  queue_visible_tiles();
  update_touch_subscription();
  refresh_motion_detection_service();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void fixture_perf_maybe_emit(void) {
  if (!s_fixture_perf_active || s_visual_animation_timer ||
      visual_animations_active()) {
    return;
  }
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_PERF e=%lu t=%lu d=%lu b=%lu B=%lu g=%lu l=%lu m=%lu x=%lu u=%lu v=%lu p=%lu o=%lu c=%lu q=%lu/%lu s=%lu",
          (unsigned long)s_fixture_perf.errors,
          (unsigned long)s_fixture_perf.scheduler_ticks,
          (unsigned long)s_fixture_perf.map_draws,
          (unsigned long)s_fixture_perf.bearing_steps,
          (unsigned long)s_fixture_perf.bearing_advances,
          (unsigned long)s_fixture_perf.gps_advances,
          (unsigned long)s_fixture_perf.tile_advances,
          (unsigned long)s_fixture_perf.menu_advances,
          (unsigned long)s_fixture_perf.multi_source_ticks,
          (unsigned long)s_fixture_perf.manual_browse_bearing_ticks,
          (unsigned long)s_fixture_perf.manual_browse_map_errors,
          (unsigned long)s_fixture_perf.route_projection_recomputes,
          (unsigned long)s_fixture_perf.orientation_work,
          (unsigned long)s_fixture_perf.route_segments_clipped,
          (unsigned long)s_fixture_perf.map_draw_time_ms,
          (unsigned long)s_fixture_perf.max_map_draw_time_ms,
          (unsigned long)s_fixture_perf.route_segments_submitted);
  s_fixture_perf_active = false;
}

#endif
