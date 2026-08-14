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
  uint32_t inertia_advances;
  uint32_t inertia_steps;
  uint32_t multi_source_ticks;
  uint32_t manual_browse_bearing_ticks;
  uint32_t manual_browse_map_errors;
  uint32_t route_projection_recomputes;
  uint32_t orientation_work;
  uint32_t route_segments_submitted;
  uint32_t route_segments_clipped;
  uint32_t map_draw_time_ms;
  uint32_t max_map_draw_time_ms;
  uint32_t rotated_destination_pixels;
  uint32_t rotated_sample_attempts;
  uint32_t rotated_packed_hits;
  uint32_t rotated_rle_hits;
  uint32_t rotated_rle_misses;
  uint32_t rotated_rle_decoded_pixels;
  uint32_t rotated_passes;
  uint32_t rotated_cardinal_passes;
  uint32_t rotated_dda_passes;
  uint32_t rotated_scaled_passes;
  uint32_t rotated_decode_errors;
  uint32_t errors;
} FixturePerfCounters;

static FixturePerfCounters s_fixture_perf;
static bool s_fixture_perf_active;
static uint16_t s_fixture_perf_draw_started_ms;
static bool s_fixture_pan_active;
static bool s_fixture_pan_input_pending;
static uint16_t s_fixture_pan_input_ms;
static bool s_fixture_inertia_measurement;
static int32_t s_fixture_inertia_start_x;
static int32_t s_fixture_inertia_start_y;
static time_t s_fixture_inertia_started_s;
static uint16_t s_fixture_inertia_started_ms;
static int32_t s_fixture_inertia_settle_ms;
static AppTimer *s_fixture_cancel_verify_timer;
static uint16_t s_fixture_cancel_failures;
static uint8_t s_fixture_cancel_action;
static bool s_fixture_cancel_started;

enum {
  FixtureCancelStartFailed = 1 << 0,
  FixtureCancelStillActive = 1 << 1,
  FixtureCancelPauseMissing = 1 << 2,
  FixtureCancelGraceMissing = 1 << 3,
  FixtureCancelNewTouchResumed = 1 << 4,
  FixtureCancelTouchActive = 1 << 5,
  FixtureCancelFinalActive = 1 << 6,
  FixtureCancelPauseStranded = 1 << 7,
  FixtureCancelGraceStranded = 1 << 8,
  FixtureCancelVerifyTimerFailed = 1 << 9,
};

static int32_t fixture_elapsed_ms(time_t start_seconds, uint16_t start_ms,
                                  time_t end_seconds, uint16_t end_ms) {
  int32_t elapsed_seconds = (int32_t)(
      (int64_t)end_seconds - (int64_t)start_seconds);
  return elapsed_seconds * 1000 +
      (int32_t)end_ms - start_ms;
}

void fixture_perf_begin(void) {
  memset(&s_fixture_perf, 0, sizeof(s_fixture_perf));
  s_fixture_pan_input_pending = false;
  s_fixture_inertia_measurement = false;
  s_fixture_perf_active = true;
}

void fixture_perf_bearing_immediate_step(void) {
  if (s_fixture_perf_active) {
    s_fixture_perf.bearing_steps++;
  }
}

void fixture_perf_scheduler_tick(bool bearing_active, bool gps_active,
                                 bool tile_active, bool menu_active,
                                 bool inertia_active, bool bearing_changed,
                                 bool inertia_changed) {
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
  if (inertia_active) {
    s_fixture_perf.inertia_advances++;
    active_sources++;
  }
  if (bearing_changed) {
    s_fixture_perf.bearing_steps++;
  }
  if (inertia_changed) {
    s_fixture_perf.inertia_steps++;
  }
  if (inertia_active && s_fixture_inertia_measurement &&
      !pan_inertia_animation_active()) {
    time_t tick_seconds;
    uint16_t tick_ms;
    time_ms(&tick_seconds, &tick_ms);
    s_fixture_inertia_settle_ms = fixture_elapsed_ms(
        s_fixture_inertia_started_s, s_fixture_inertia_started_ms,
        tick_seconds, tick_ms);
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
  if (s_fixture_pan_input_pending) {
    s_fixture_pan_input_pending = false;
    int32_t input_ms = (int32_t)now_ms - s_fixture_pan_input_ms;
    if (input_ms < 0) {
      input_ms += 1000;
    }
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_PAN_FRAME i=%ld", (long)input_ms);
  }
}

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
                                 uint32_t decode_errors) {
  if (!s_fixture_perf_active) {
    return;
  }
  s_fixture_perf.rotated_destination_pixels += destination_pixels;
  s_fixture_perf.rotated_sample_attempts += sample_attempts;
  s_fixture_perf.rotated_packed_hits += packed_hits;
  s_fixture_perf.rotated_rle_hits += rle_hits;
  s_fixture_perf.rotated_rle_misses += rle_misses;
  s_fixture_perf.rotated_rle_decoded_pixels += rle_decoded_pixels;
  s_fixture_perf.rotated_passes += passes;
  s_fixture_perf.rotated_cardinal_passes += cardinal_passes;
  s_fixture_perf.rotated_dda_passes += dda_passes;
  s_fixture_perf.rotated_scaled_passes += scaled_passes;
  s_fixture_perf.rotated_decode_errors += decode_errors;
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

static bool fixture_cancel_touch_active(void) {
#ifdef PBL_TOUCH
  return s_touch_active;
#else
  return false;
#endif
}

static void fixture_cancel_verify_callback(void *context) {
  (void)context;
  s_fixture_cancel_verify_timer = NULL;
  if (pan_inertia_animation_active()) {
    s_fixture_cancel_failures |= FixtureCancelFinalActive;
  }
  if (s_tile_requests_interaction_paused) {
    s_fixture_cancel_failures |= FixtureCancelPauseStranded;
  }
  if (s_tile_request_resume_timer) {
    s_fixture_cancel_failures |= FixtureCancelGraceStranded;
  }
  if (fixture_cancel_touch_active()) {
    s_fixture_cancel_failures |= FixtureCancelTouchActive;
  }
  if (s_fixture_cancel_failures != 0) {
    s_fixture_perf.errors++;
  }
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_PAN_CANCEL kind=%u started=%d f=%u active=%d paused=%d grace=%d touch=%d",
          (unsigned)s_fixture_cancel_action,
          s_fixture_cancel_started ? 1 : 0,
          (unsigned)s_fixture_cancel_failures,
          pan_inertia_animation_active() ? 1 : 0,
          s_tile_requests_interaction_paused ? 1 : 0,
          s_tile_request_resume_timer ? 1 : 0,
          fixture_cancel_touch_active() ? 1 : 0);
  s_fixture_pan_active = false;
  fixture_perf_maybe_emit();
}

static void fixture_perf_cancel_pan(int action, int16_t screen_x,
                                    int16_t screen_y) {
  const int32_t viewport_dx = -60;
  const int32_t viewport_dy = -12;
  if (s_fixture_cancel_verify_timer) {
    app_timer_cancel(s_fixture_cancel_verify_timer);
    s_fixture_cancel_verify_timer = NULL;
  }
  fixture_perf_begin();
  s_fixture_pan_active = true;
  s_fixture_cancel_action = (uint8_t)action;
  s_fixture_cancel_failures = 0;
  s_fixture_cancel_started = s_has_gps && s_map_layer &&
      fixture_start_pan_inertia(viewport_dx, viewport_dy,
                                VISUAL_ANIMATION_TICK_MS);
  if (!s_fixture_cancel_started) {
    s_fixture_cancel_failures |= FixtureCancelStartFailed;
  } else if (action == 6) {
    begin_pan_interaction(screen_x, screen_y);
    if (pan_inertia_animation_active()) {
      s_fixture_cancel_failures |= FixtureCancelStillActive;
    }
    if (!s_tile_requests_interaction_paused) {
      s_fixture_cancel_failures |= FixtureCancelPauseMissing;
    }
    if (s_tile_request_resume_timer) {
      s_fixture_cancel_failures |= FixtureCancelNewTouchResumed;
    }
    end_pan_interaction(screen_x, screen_y);
  } else if (action == 7) {
    change_zoom(s_viewport_zoom < MAX_MAP_ZOOM ? 1 : -1);
  } else if (action == 8) {
    recenter_viewport();
  } else {
    open_menu(MenuSettings);
    close_menu();
  }

  if (pan_inertia_animation_active()) {
    s_fixture_cancel_failures |= FixtureCancelStillActive;
  }
  if (!s_tile_requests_interaction_paused) {
    s_fixture_cancel_failures |= FixtureCancelPauseMissing;
  }
  if (!s_tile_request_resume_timer) {
    s_fixture_cancel_failures |= FixtureCancelGraceMissing;
  }
  if (fixture_cancel_touch_active()) {
    s_fixture_cancel_failures |= FixtureCancelTouchActive;
  }

  s_fixture_cancel_verify_timer = app_timer_register(
      TILE_REQUEST_TOUCH_RESUME_MS + 50,
      fixture_cancel_verify_callback, NULL);
  if (!s_fixture_cancel_verify_timer) {
    s_fixture_cancel_failures |= FixtureCancelVerifyTimerFailed;
    fixture_cancel_verify_callback(NULL);
  }
}

void fixture_perf_pan_under_load(int action) {
  int16_t screen_x = s_screen_bounds.size.w / 2;
  int16_t screen_y = s_screen_bounds.size.h / 2;
  if (action >= 6 && action <= 9) {
    fixture_perf_cancel_pan(action, screen_x, screen_y);
    return;
  }
  if (action == 5) {
    const int32_t viewport_dx = -60;
    const int32_t viewport_dy = -12;
    const uint16_t elapsed_ms = VISUAL_ANIMATION_TICK_MS;
    fixture_perf_begin();
    s_fixture_pan_active = false;
    s_fixture_pan_input_ms = time_ms(NULL, NULL);
    s_fixture_pan_input_pending = true;
    bool started = s_has_gps && s_map_layer &&
        fixture_start_pan_inertia(viewport_dx, viewport_dy, elapsed_ms);
    if (started) {
      s_fixture_inertia_start_x = s_viewport_x;
      s_fixture_inertia_start_y = s_viewport_y;
      time_ms(&s_fixture_inertia_started_s,
              &s_fixture_inertia_started_ms);
      s_fixture_inertia_settle_ms = -1;
      s_fixture_inertia_measurement = true;
    } else {
      s_fixture_pan_input_pending = false;
      s_fixture_perf.errors++;
    }
    APP_LOG(APP_LOG_LEVEL_INFO,
            "MAPPY_PAN_INERTIA active=%d dx=%ld dy=%ld",
            started ? 1 : 0, (long)viewport_dx, (long)viewport_dy);
    if (!started) {
      fixture_perf_maybe_emit();
    }
    return;
  }
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
    bool started = false;
    if (s_tiles) {
      int capacity = active_tile_cache_size();
      for (int i = 0; i < capacity; i++) {
        if (!s_tiles[i].valid || !tile_is_visible(&s_tiles[i])) {
          continue;
        }
        started = start_tile_animation(&s_tiles[i], true);
        if (!s_tiles[i].animation_active) {
          s_fixture_perf.errors++;
        }
        break;
      }
    }
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_PAN_ANIMATION active=%d",
            started ? 1 : 0);
    // Finish the fixture measurement in the same AppMessage dispatch that
    // starts the post-pan animation. A second fixture command can be accepted
    // by the emulator transport without reaching the watch, which otherwise
    // leaves this measurement active until the host times out.
    s_fixture_pan_active = false;
    fixture_perf_maybe_emit();
  }
}

void fixture_perf_maybe_emit(void) {
  if (!s_fixture_perf_active || s_fixture_pan_active ||
      s_visual_animation_timer ||
      visual_animations_active()) {
    return;
  }
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_RPERF p=%lu s=%lu k=%lu h=%lu m=%lu r=%lu a=%lu c=%lu d=%lu z=%lu e=%lu",
          (unsigned long)s_fixture_perf.rotated_destination_pixels,
          (unsigned long)s_fixture_perf.rotated_sample_attempts,
          (unsigned long)s_fixture_perf.rotated_packed_hits,
          (unsigned long)s_fixture_perf.rotated_rle_hits,
          (unsigned long)s_fixture_perf.rotated_rle_misses,
          (unsigned long)s_fixture_perf.rotated_rle_decoded_pixels,
          (unsigned long)s_fixture_perf.rotated_passes,
          (unsigned long)s_fixture_perf.rotated_cardinal_passes,
          (unsigned long)s_fixture_perf.rotated_dda_passes,
          (unsigned long)s_fixture_perf.rotated_scaled_passes,
          (unsigned long)s_fixture_perf.rotated_decode_errors);
  int32_t inertia_settle_ms = s_fixture_inertia_measurement ?
      s_fixture_inertia_settle_ms : 0;
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_IPERF a=%lu c=%lu x=%ld y=%ld ms=%ld",
          (unsigned long)s_fixture_perf.inertia_advances,
          (unsigned long)s_fixture_perf.inertia_steps,
          s_fixture_inertia_measurement ?
              (long)(s_viewport_x - s_fixture_inertia_start_x) : 0L,
          s_fixture_inertia_measurement ?
              (long)(s_viewport_y - s_fixture_inertia_start_y) : 0L,
          (long)inertia_settle_ms);
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
  s_fixture_inertia_measurement = false;
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
static bool s_hardware_perf_coast_measurement;
static bool s_hardware_perf_coast_started;
static bool s_hardware_perf_coast_settled;
static bool s_hardware_perf_coast_cancelled;
static bool s_hardware_perf_coast_draw_pending;
static time_t s_hardware_perf_coast_release_seconds;
static uint16_t s_hardware_perf_coast_release_ms;
static int32_t s_hardware_perf_coast_first_frame_ms;
static int32_t s_hardware_perf_coast_settle_ms;
static uint32_t s_hardware_perf_coast_draw_total_ms;
static uint32_t s_hardware_perf_coast_draw_max_ms;
static uint16_t s_hardware_perf_coast_run;
static uint16_t s_hardware_perf_coast_gesture;
static uint8_t s_hardware_perf_coast_ticks;
static uint8_t s_hardware_perf_coast_frames;
static int8_t s_hardware_perf_coast_zoom;
static int16_t s_hardware_perf_coast_tile_width;
static int16_t s_hardware_perf_coast_tile_height;
static bool s_hardware_perf_coast_orientation_active;

static int32_t hardware_perf_elapsed_ms(time_t start_seconds,
                                        uint16_t start_ms,
                                        time_t end_seconds,
                                        uint16_t end_ms) {
  int64_t elapsed = ((int64_t)end_seconds - (int64_t)start_seconds) * 1000 +
      (int32_t)end_ms - (int32_t)start_ms;
  if (elapsed > INT32_MAX) {
    return INT32_MAX;
  }
  if (elapsed < INT32_MIN) {
    return INT32_MIN;
  }
  return (int32_t)elapsed;
}

static void hardware_perf_emit_pan_coast(void) {
  if (!s_hardware_perf_coast_measurement) {
    return;
  }
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_HW_COAST r=%u g=%u k=%d t=%u f=%u i=%ld d=%lu/%lu ms=%ld c=%d z=%d w=%d h=%d o=%d",
          (unsigned)s_hardware_perf_coast_run,
          (unsigned)s_hardware_perf_coast_gesture,
          s_hardware_perf_coast_started ? 1 : 0,
          (unsigned)s_hardware_perf_coast_ticks,
          (unsigned)s_hardware_perf_coast_frames,
          (long)s_hardware_perf_coast_first_frame_ms,
          (unsigned long)s_hardware_perf_coast_draw_total_ms,
          (unsigned long)s_hardware_perf_coast_draw_max_ms,
          (long)s_hardware_perf_coast_settle_ms,
          s_hardware_perf_coast_cancelled ? 1 : 0,
          (int)s_hardware_perf_coast_zoom,
          (int)s_hardware_perf_coast_tile_width,
          (int)s_hardware_perf_coast_tile_height,
          s_hardware_perf_coast_orientation_active ? 1 : 0);
  s_hardware_perf_coast_measurement = false;
  s_hardware_perf_coast_draw_pending = false;
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

void hardware_perf_pan_release(bool inertia_started) {
  // A previous cancelled coast normally renders before another liftoff. If it
  // did not, preserve its aggregate rather than overwriting it.
  if (s_hardware_perf_coast_measurement &&
      !s_hardware_perf_coast_settled) {
    hardware_perf_pan_settled(s_hardware_perf_coast_ticks, true);
  }
  hardware_perf_emit_pan_coast();
  s_hardware_perf_coast_measurement = true;
  s_hardware_perf_coast_started = inertia_started;
  s_hardware_perf_coast_settled = false;
  s_hardware_perf_coast_cancelled = false;
  s_hardware_perf_coast_draw_pending = false;
  s_hardware_perf_coast_release_ms = time_ms(
      &s_hardware_perf_coast_release_seconds, NULL);
  s_hardware_perf_coast_first_frame_ms = -1;
  s_hardware_perf_coast_settle_ms = -1;
  s_hardware_perf_coast_draw_total_ms = 0;
  s_hardware_perf_coast_draw_max_ms = 0;
  s_hardware_perf_coast_run = s_hardware_perf_run;
  s_hardware_perf_coast_gesture = s_hardware_perf_gesture;
  s_hardware_perf_coast_ticks = 0;
  s_hardware_perf_coast_frames = 0;
  s_hardware_perf_coast_zoom = s_viewport_zoom;
  s_hardware_perf_coast_tile_width = (int16_t)s_tile_width;
  s_hardware_perf_coast_tile_height = (int16_t)s_tile_height;
  s_hardware_perf_coast_orientation_active = map_orientation_active();
}

void hardware_perf_pan_settled(uint8_t ticks, bool cancelled) {
  if (!s_hardware_perf_coast_measurement || s_hardware_perf_coast_settled) {
    return;
  }
  time_t now_seconds;
  uint16_t now_ms = time_ms(&now_seconds, NULL);
  s_hardware_perf_coast_ticks = ticks;
  s_hardware_perf_coast_cancelled = cancelled;
  s_hardware_perf_coast_settle_ms = hardware_perf_elapsed_ms(
      s_hardware_perf_coast_release_seconds,
      s_hardware_perf_coast_release_ms, now_seconds, now_ms);
  s_hardware_perf_coast_settled = true;
}

void hardware_perf_flush_pan(void) {
  if (s_hardware_perf_coast_measurement &&
      !s_hardware_perf_coast_settled) {
    hardware_perf_pan_settled(s_hardware_perf_coast_ticks, true);
  }
  hardware_perf_emit_pan_coast();
}

void hardware_perf_map_draw_begin(void) {
  s_hardware_perf_draw_pending = s_hardware_perf_input_pending;
  s_hardware_perf_coast_draw_pending =
      s_hardware_perf_coast_measurement;
  if (s_hardware_perf_draw_pending ||
      s_hardware_perf_coast_draw_pending) {
    s_hardware_perf_draw_ms =
        time_ms(&s_hardware_perf_draw_seconds, NULL);
  }
}

void hardware_perf_map_draw_complete(void) {
  bool input_draw = s_hardware_perf_input_pending &&
      s_hardware_perf_draw_pending;
  bool coast_draw = s_hardware_perf_coast_measurement &&
      s_hardware_perf_coast_draw_pending;
  if (!input_draw && !coast_draw) {
    return;
  }
  time_t now_seconds;
  uint16_t now_ms = time_ms(&now_seconds, NULL);
  int32_t draw_ms = hardware_perf_elapsed_ms(
      s_hardware_perf_draw_seconds, s_hardware_perf_draw_ms,
      now_seconds, now_ms);
  if (draw_ms < 0) {
    draw_ms = 0;
  }

  if (input_draw) {
    int32_t input_ms = hardware_perf_elapsed_ms(
        s_hardware_perf_input_seconds, s_hardware_perf_input_ms,
        now_seconds, now_ms);
    APP_LOG(APP_LOG_LEVEL_INFO,
            "MAPPY_HW_FRAME r=%u g=%u i=%ld d=%ld z=%d w=%d h=%d o=%d a=%d f=%u",
            (unsigned)s_hardware_perf_run, (unsigned)s_hardware_perf_gesture,
            (long)input_ms, (long)draw_ms,
            (int)s_viewport_zoom, s_tile_width, s_tile_height,
            map_orientation_active() ? 1 : 0, s_tile_animation_mode,
            (unsigned)s_hardware_perf_input_flights);
    s_hardware_perf_input_pending = false;
  }
  s_hardware_perf_draw_pending = false;

  if (coast_draw) {
    if (s_hardware_perf_coast_frames == 0) {
      s_hardware_perf_coast_first_frame_ms = hardware_perf_elapsed_ms(
          s_hardware_perf_coast_release_seconds,
          s_hardware_perf_coast_release_ms, now_seconds, now_ms);
    }
    if (s_hardware_perf_coast_frames < UINT8_MAX) {
      s_hardware_perf_coast_frames++;
    }
    s_hardware_perf_coast_draw_total_ms += (uint32_t)draw_ms;
    if ((uint32_t)draw_ms > s_hardware_perf_coast_draw_max_ms) {
      s_hardware_perf_coast_draw_max_ms = (uint32_t)draw_ms;
    }
    s_hardware_perf_coast_draw_pending = false;
    if (s_hardware_perf_coast_settled) {
      hardware_perf_emit_pan_coast();
    }
  }
}

#endif
