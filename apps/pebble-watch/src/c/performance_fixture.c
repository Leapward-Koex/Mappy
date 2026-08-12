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
static bool s_fixture_perf_active;
static uint16_t s_fixture_perf_draw_started_ms;
static bool s_fixture_pan_active;
static bool s_fixture_pan_input_pending;
static uint16_t s_fixture_pan_input_ms;

void fixture_perf_begin(void) {
  memset(&s_fixture_perf, 0, sizeof(s_fixture_perf));
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
    s_fixture_perf_draw_started_ms = time_ms(NULL, NULL);
  }
}

void fixture_perf_map_draw_complete(void) {
  if (!s_fixture_perf_active) {
    return;
  }
  uint16_t now_ms = time_ms(NULL, NULL);
  int32_t elapsed = (int32_t)now_ms - s_fixture_perf_draw_started_ms;
  if (elapsed < 0) {
    elapsed += 1000;
  }
  s_fixture_perf.map_draw_time_ms += (uint32_t)elapsed;
  if ((uint32_t)elapsed > s_fixture_perf.max_map_draw_time_ms) {
    s_fixture_perf.max_map_draw_time_ms = (uint32_t)elapsed;
  }
  if (s_fixture_pan_active && s_fixture_pan_input_pending) {
    s_fixture_pan_input_pending = false;
    int32_t input_ms = (int32_t)now_ms - s_fixture_pan_input_ms;
    if (input_ms < 0) {
      input_ms += 1000;
    }
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_PAN_FRAME i=%ld", (long)input_ms);
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

void fixture_set_location_screen_position(int32_t screen_x, int32_t screen_y) {
  if (!s_has_gps) {
    return;
  }

  complete_tile_animations();
  complete_gps_smoothing();
  cancel_menu_highlight_animation();
  s_menu_mode = MenuNone;
  s_menu_selection = 0;
  s_manual_pan = true;

  int32_t gps_x = scale_world_to_zoom(s_gps_world_x, s_gps_zoom,
                                      s_viewport_zoom);
  int32_t gps_y = scale_world_to_zoom(s_gps_world_y, s_gps_zoom,
                                      s_viewport_zoom);
  s_viewport_x = gps_x - (screen_x - s_screen_bounds.size.w / 2);
  s_viewport_y = gps_y - (screen_y - s_screen_bounds.size.h / 2);

  sync_map_bearing_smoothing(false);
  update_state_after_map_change();
  queue_visible_tiles();
  update_touch_subscription();
  refresh_motion_detection_service();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void fixture_perf_pan_under_load(int action) {
  int16_t screen_x = s_screen_bounds.size.w / 2;
  int16_t screen_y = s_screen_bounds.size.h / 2;
  if (action == 3) {
    fixture_perf_begin();
    s_fixture_pan_active = true;
    s_fixture_pan_input_pending = false;
    if (!s_has_gps || !s_map_layer) {
      s_fixture_perf.errors++;
    }
    begin_pan_interaction(screen_x, screen_y);
    update_pan_interaction(screen_x + 16, screen_y + 6);
    end_pan_interaction(screen_x + 24, screen_y + 9);
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_PAN_START");
    return;
  }
  if (action == 0) {
    fixture_perf_begin();
    s_fixture_pan_active = s_has_gps && s_map_layer;
    s_fixture_pan_input_pending = false;
    invalidate_tiles_with_reason(TileInvalidateTheme);
    change_zoom(s_viewport_zoom < MAX_MAP_ZOOM ? 1 : -1);
    begin_pan_interaction(screen_x, screen_y);
    update_pan_interaction(screen_x + 16, screen_y + 6);
    end_pan_interaction(screen_x + 24, screen_y + 9);
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_PAN_START");
    return;
  }
  if (!s_fixture_pan_active) {
    return;
  }
  if (action == 1) {
    s_fixture_pan_input_ms = time_ms(NULL, NULL);
    s_fixture_pan_input_pending = true;
    begin_pan_interaction(screen_x, screen_y);
    update_pan_interaction(screen_x + 32, screen_y + 12);
    end_pan_interaction(screen_x + 48, screen_y + 18);
  } else if (action == 2) {
    s_fixture_pan_active = false;
    fixture_perf_maybe_emit();
  } else if (action == 4) {
    if (s_tiles) {
      int capacity = active_tile_cache_size();
      for (int i = 0; i < capacity; i++) {
        if (!s_tiles[i].valid || !tile_is_visible(&s_tiles[i])) {
          continue;
        }
        start_tile_animation(&s_tiles[i], true);
        if (!s_tiles[i].animation_active) {
          s_fixture_perf.errors++;
        }
        break;
      }
    }
  }
}

void fixture_perf_maybe_emit(void) {
  if (!s_fixture_perf_active || s_fixture_pan_active ||
      s_visual_animation_timer ||
      visual_animations_active()) {
    return;
  }
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_PERF e=%lu t=%lu d=%lu b=%lu B=%lu g=%lu l=%lu m=%lu x=%lu u=%lu v=%lu o=%lu p=%lu c=%lu q=%lu/%lu s=%lu",
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
          (unsigned long)s_fixture_perf.orientation_work,
          (unsigned long)s_fixture_perf.route_projection_recomputes,
          (unsigned long)s_fixture_perf.route_segments_clipped,
          (unsigned long)s_fixture_perf.map_draw_time_ms,
          (unsigned long)s_fixture_perf.max_map_draw_time_ms,
          (unsigned long)s_fixture_perf.route_segments_submitted);
  s_fixture_perf_active = false;
}

#endif

#ifdef MAPPY_WATCH_HARDWARE_PERF

static bool s_hardware_perf_sampled;
static bool s_hardware_perf_input_pending;
static bool s_hardware_perf_draw_pending;
static uint16_t s_hardware_perf_run;
static uint16_t s_hardware_perf_gesture;
static time_t s_hardware_perf_input_seconds;
static uint16_t s_hardware_perf_input_ms;
static uint8_t s_hardware_perf_input_flights;
static time_t s_hardware_perf_draw_seconds;
static uint16_t s_hardware_perf_draw_ms;

static int32_t hardware_perf_elapsed_ms(time_t start_seconds,
                                        uint16_t start_ms,
                                        time_t end_seconds,
                                        uint16_t end_ms) {
  return (int32_t)(end_seconds - start_seconds) * 1000 +
      (int32_t)end_ms - (int32_t)start_ms;
}

void hardware_perf_begin_pan(void) {
  s_hardware_perf_gesture++;
  s_hardware_perf_sampled = false;
  s_hardware_perf_input_pending = false;
  s_hardware_perf_draw_pending = false;
}

void hardware_perf_begin_zoom(void) {
  s_hardware_perf_run++;
  s_hardware_perf_gesture = 0;
  s_hardware_perf_sampled = false;
  s_hardware_perf_input_pending = false;
  s_hardware_perf_draw_pending = false;
}

void hardware_perf_note_pan_input(time_t seconds, uint16_t milliseconds) {
  if (s_hardware_perf_sampled) {
    return;
  }
  s_hardware_perf_input_seconds = seconds;
  s_hardware_perf_input_ms = milliseconds;
  s_hardware_perf_input_flights = (uint8_t)active_tile_flight_count();
  s_hardware_perf_sampled = true;
  s_hardware_perf_input_pending = true;
}

void hardware_perf_map_draw_begin(void) {
  s_hardware_perf_draw_pending = s_hardware_perf_input_pending;
  if (s_hardware_perf_draw_pending) {
    s_hardware_perf_draw_ms =
        time_ms(&s_hardware_perf_draw_seconds, NULL);
  }
}

void hardware_perf_map_draw_complete(void) {
  if (!s_hardware_perf_input_pending || !s_hardware_perf_draw_pending) {
    return;
  }
  time_t now_seconds;
  uint16_t now_ms = time_ms(&now_seconds, NULL);
  int32_t input_ms = hardware_perf_elapsed_ms(
      s_hardware_perf_input_seconds, s_hardware_perf_input_ms,
      now_seconds, now_ms);
  int32_t draw_ms = hardware_perf_elapsed_ms(
      s_hardware_perf_draw_seconds, s_hardware_perf_draw_ms,
      now_seconds, now_ms);
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_HW_FRAME r=%u g=%u i=%ld d=%ld z=%d w=%d h=%d o=%d a=%d f=%u",
          (unsigned)s_hardware_perf_run, (unsigned)s_hardware_perf_gesture,
          (long)input_ms, (long)draw_ms,
          (int)s_viewport_zoom, s_tile_width, s_tile_height,
          map_orientation_active() ? 1 : 0, s_tile_animation_mode,
          (unsigned)s_hardware_perf_input_flights);
  s_hardware_perf_input_pending = false;
  s_hardware_perf_draw_pending = false;
}

#endif
