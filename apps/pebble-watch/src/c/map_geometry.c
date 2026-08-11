#include "mappy.h"

// World/screen projection, heading, compass, and map-orientation math.

int32_t floor_div_i32(int32_t value, int32_t divisor) {
  int32_t quotient = value / divisor;
  int32_t remainder = value % divisor;
  if (remainder != 0 && ((remainder < 0) != (divisor < 0))) {
    quotient--;
  }
  return quotient;
}

int32_t scale_world_to_zoom(int32_t value, int8_t from_zoom, int8_t to_zoom) {
  if (to_zoom > from_zoom) {
    return value << (to_zoom - from_zoom);
  }
  if (to_zoom < from_zoom) {
    return value >> (from_zoom - to_zoom);
  }
  return value;
}

int32_t clamp_i32_to_i16(int32_t value) {
  if (value > 32767) {
    return 32767;
  }
  if (value < -32768) {
    return -32768;
  }
  return value;
}

int32_t normalize_degrees(int32_t degrees) {
  int32_t normalized = degrees % 360;
  if (normalized < 0) {
    normalized += 360;
  }
  return normalized;
}

static int32_t normalize_centi_degrees(int32_t centi_degrees) {
  int32_t normalized = centi_degrees % 36000;
  if (normalized < 0) {
    normalized += 36000;
  }
  return normalized;
}

static int32_t rounded_degrees_from_centi(int32_t centi_degrees) {
  return ((normalize_centi_degrees(centi_degrees) + 50) / 100) % 360;
}

static int32_t target_map_bearing_centi_degrees(void) {
#if defined(PBL_COMPASS)
  if (compass_heading_is_valid()) {
    return normalize_degrees(s_compass_heading_degrees) * 100;
  }
  return -1;
#else
  if (phone_heading_is_usable()) {
    return normalized_phone_heading_degrees() * 100;
  }
  return -1;
#endif
}

void update_map_after_bearing_display_change(bool was_orientation_active) {
  bool orientation_active = map_orientation_active();
  if (was_orientation_active && !orientation_active) {
    invalidate_orientation_tile_coverage();
    update_state_after_map_change();
    queue_visible_tiles();
    return;
  }
  if (orientation_active) {
    if (orientation_tile_coverage_changed()) {
      update_state_after_map_change();
      queue_visible_tiles();
    } else {
      send_next_tile_request();
    }
  }
}

static int32_t trig_angle_from_centi_degrees(int32_t centi_degrees) {
  return (int32_t)(((int64_t)TRIG_MAX_ANGLE *
                    normalize_centi_degrees(centi_degrees)) / 36000);
}

static int32_t trig_ratio_to_int(int64_t value) {
#if TRIG_MAX_RATIO == (1 << TRIG_RATIO_SHIFT)
  if (value >= 0) {
    return (int32_t)(value >> TRIG_RATIO_SHIFT);
  }
  return -(int32_t)((-value) >> TRIG_RATIO_SHIFT);
#else
  return (int32_t)(value / TRIG_MAX_RATIO);
#endif
}

bool phone_heading_is_valid(void) {
  return s_heading_degrees >= 0 && s_heading_degrees <= 360;
}

bool gps_fix_fresh_for_seconds(int seconds) {
  if (!s_has_gps || s_gps_received_at == 0) {
    return false;
  }
  time_t now = time(NULL);
  if (now < s_gps_received_at) {
    return true;
  }
  return now - s_gps_received_at <= seconds;
}

bool phone_heading_is_usable(void) {
  return phone_heading_is_valid() && gps_fix_fresh_for_seconds(HEADING_FRESH_SECONDS);
}

int32_t normalized_phone_heading_degrees(void) {
  return normalize_degrees(s_heading_degrees);
}

bool compass_heading_is_valid(void) {
  return s_compass_heading_degrees >= 0 && s_compass_heading_degrees < 360;
}

bool compass_magnetic_heading_is_valid(void) {
  return s_compass_magnetic_degrees >= 0 && s_compass_magnetic_degrees < 360;
}

int32_t corrected_compass_heading_degrees(int32_t magnetic_degrees) {
  int32_t centi_degrees = normalize_degrees(magnetic_degrees) * 100;
  if (s_declination_valid) {
    centi_degrees += s_declination_centi_degrees;
  }
  centi_degrees %= 36000;
  if (centi_degrees < 0) {
    centi_degrees += 36000;
  }
  return (centi_degrees + 50) / 100 % 360;
}

void refresh_corrected_compass_heading(void) {
  if (compass_magnetic_heading_is_valid()) {
    s_compass_heading_degrees =
        corrected_compass_heading_degrees(s_compass_magnetic_degrees);
  } else {
    s_compass_heading_degrees = -1;
  }
}

#if defined(PBL_COMPASS)
static CompassFilter s_compass_filter;
static AppTimer *s_compass_health_timer;
static AppTimer *s_compass_outlier_timer;
static bool s_compass_focused = true;
static uint16_t s_compass_rejected_outlier_count;
static uint32_t s_compass_last_outlier_log_ms;

static uint32_t compass_now_ms(void) {
  time_t seconds;
  uint16_t milliseconds;
  time_ms(&seconds, &milliseconds);
  return (uint32_t)seconds * 1000u + milliseconds;
}

int32_t compass_heading_to_degrees(CompassHeading heading) {
  // Pebble compass headings increase counter-clockwise; app rendering uses clockwise degrees.
  int32_t counter_clockwise_heading = heading % TRIG_MAX_ANGLE;
  if (counter_clockwise_heading < 0) {
    counter_clockwise_heading += TRIG_MAX_ANGLE;
  }
  int32_t clockwise_heading =
      (TRIG_MAX_ANGLE - counter_clockwise_heading) % TRIG_MAX_ANGLE;
  return (int32_t)(((int64_t)clockwise_heading * 360) / TRIG_MAX_ANGLE);
}

static int compass_diagnostic_state(void) {
  if (s_compass_filter.stale) {
    return 3;
  }
  return (int)s_compass_filter.status;
}

static void send_compass_log(const char *event_name, int detail) {
  send_log_event(0, detail, s_declination_valid ? 1 : 0, event_name);
}

void emit_compass_state_diagnostic(void) {
  if (!s_compass_filter.status_known && !s_compass_filter.stale) {
    return;
  }
  send_compass_log(s_compass_filter.heading_usable ?
      "compass_heading_acquired" : "compass_heading_lost",
      compass_diagnostic_state());
}

static void emit_rejected_outlier_diagnostic(uint32_t now_ms) {
  if (s_compass_rejected_outlier_count < UINT16_MAX) {
    s_compass_rejected_outlier_count++;
  }
  if (s_compass_last_outlier_log_ms != 0 &&
      now_ms - s_compass_last_outlier_log_ms <
          COMPASS_OUTLIER_LOG_INTERVAL_MS) {
    return;
  }
  send_compass_log("compass_outlier_rejected",
                   s_compass_rejected_outlier_count);
  s_compass_rejected_outlier_count = 0;
  s_compass_last_outlier_log_ms = now_ms;
}

static void cancel_compass_outlier_timer(void) {
  if (s_compass_outlier_timer) {
    app_timer_cancel(s_compass_outlier_timer);
    s_compass_outlier_timer = NULL;
  }
}

static void compass_peek(void);

static void compass_outlier_timer_callback(void *context) {
  (void)context;
  s_compass_outlier_timer = NULL;
  if (!s_compass_focused || !s_compass_filter.outlier_pending) {
    return;
  }
  compass_peek();
}

static void schedule_compass_outlier_confirmation(uint32_t now_ms) {
  if (!s_compass_filter.outlier_pending || !s_compass_focused ||
      s_compass_outlier_timer) {
    return;
  }
  uint32_t elapsed = now_ms - s_compass_filter.outlier_started_ms;
  uint32_t delay = elapsed < COMPASS_FILTER_OUTLIER_CONFIRM_MS ?
      COMPASS_FILTER_OUTLIER_CONFIRM_MS - elapsed : 1;
  s_compass_outlier_timer = app_timer_register(
      delay, compass_outlier_timer_callback, NULL);
}

static void apply_compass_filter_result(CompassFilterResult result,
                                        uint32_t now_ms) {
  if (result == CompassFilterResultNone) {
    return;
  }

  bool was_orientation_active = map_orientation_active();
  int32_t previous_heading = s_compass_heading_degrees;
  if (s_compass_filter.heading_usable) {
    s_compass_magnetic_degrees = s_compass_filter.accepted_heading;
    s_compass_heading_degrees = corrected_compass_heading_degrees(
        s_compass_magnetic_degrees);
  } else {
    s_compass_magnetic_degrees = -1;
    s_compass_heading_degrees = -1;
  }

  if (result & CompassFilterResultCalibrationStarted) {
    send_compass_log("compass_calibration_started",
                     CompassFilterStatusCalibrating);
  }
  if (result & CompassFilterResultServiceUnavailable) {
    send_compass_log("compass_service_unavailable",
                     CompassFilterStatusUnavailable);
  }
  if (result & CompassFilterResultOutlierRejected) {
    emit_rejected_outlier_diagnostic(now_ms);
  }
  if ((result & CompassFilterResultHeadingLost) ||
      ((result & CompassFilterResultStatusChanged) &&
       !s_compass_filter.heading_usable &&
       !(result & CompassFilterResultCalibrationStarted) &&
       !(result & CompassFilterResultServiceUnavailable)) ||
      (result & CompassFilterResultStale)) {
    send_compass_log("compass_heading_lost", compass_diagnostic_state());
  }
  if ((result & CompassFilterResultHeadingAcquired) ||
      ((result & CompassFilterResultStatusChanged) &&
       s_compass_filter.heading_usable)) {
    send_compass_log("compass_heading_acquired", compass_diagnostic_state());
  }

  if (s_compass_filter.outlier_pending) {
    schedule_compass_outlier_confirmation(now_ms);
  } else {
    cancel_compass_outlier_timer();
  }

  bool heading_changed = previous_heading != s_compass_heading_degrees;
  if (result & CompassFilterResultHeadingAccepted) {
    maybe_begin_pending_route_start_reacquire();
  }
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  APP_LOG(APP_LOG_LEVEL_INFO,
          "COMPASS_FIXTURE status=%d usable=%d heading=%ld pending=%d result=%u",
          compass_diagnostic_state(), s_compass_filter.heading_usable ? 1 : 0,
          (long)s_compass_heading_degrees,
          s_compass_filter.outlier_pending ? 1 : 0, (unsigned int)result);
#endif
  bool display_changed = false;
  if (heading_changed) {
    display_changed = sync_map_bearing_smoothing(
        s_compass_filter.heading_usable);
    if (display_changed) {
      update_map_after_bearing_display_change(was_orientation_active);
    }
  }
  if ((display_changed ||
       (result & (CompassFilterResultStatusChanged |
                  CompassFilterResultHeadingAcquired |
                  CompassFilterResultHeadingLost |
                  CompassFilterResultStale))) && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

static CompassFilterStatus compass_filter_status_from_pebble(
    CompassStatus status) {
  switch (status) {
    case CompassStatusUnavailable:
      return CompassFilterStatusUnavailable;
    case CompassStatusCalibrating:
      return CompassFilterStatusCalibrating;
    case CompassStatusCalibrated:
      return CompassFilterStatusCalibrated;
    case CompassStatusDataInvalid:
    default:
      return CompassFilterStatusDataInvalid;
  }
}

const char *compass_prompt_text(void) {
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  if (s_debug_compass_override_active) {
    return NULL;
  }
#endif
  if (s_map_orientation != 1 || s_manual_pan || !s_has_gps ||
      s_compass_filter.heading_usable) {
    return NULL;
  }
  if (s_compass_filter.stale) {
    return "Compass reconnecting";
  }
  if (s_compass_filter.status_known &&
      s_compass_filter.status == CompassFilterStatusUnavailable) {
    return "Compass unavailable";
  }
  return "Move wrist to calibrate";
}

static void compass_health_timer_callback(void *context) {
  (void)context;
  s_compass_health_timer = NULL;
  if (!s_compass_focused || !s_has_gps) {
    return;
  }
  uint32_t now_ms = compass_now_ms();
  apply_compass_filter_result(compass_filter_tick(&s_compass_filter, now_ms),
                              now_ms);
  compass_peek();
  refresh_compass_health_monitoring();
}

void refresh_compass_health_monitoring(void) {
  if (!s_compass_focused || !s_has_gps) {
    if (s_compass_health_timer) {
      app_timer_cancel(s_compass_health_timer);
      s_compass_health_timer = NULL;
    }
    return;
  }
  if (!s_compass_health_timer) {
    s_compass_health_timer = app_timer_register(
        COMPASS_HEALTH_INTERVAL_MS, compass_health_timer_callback, NULL);
  }
}

static void compass_focus_handler(bool in_focus) {
  s_compass_focused = in_focus;
  if (!in_focus) {
    if (s_compass_health_timer) {
      app_timer_cancel(s_compass_health_timer);
      s_compass_health_timer = NULL;
    }
    cancel_compass_outlier_timer();
    return;
  }
  uint32_t now_ms = compass_now_ms();
  apply_compass_filter_result(compass_filter_tick(&s_compass_filter, now_ms),
                              now_ms);
  compass_peek();
  refresh_compass_health_monitoring();
}
#endif

bool active_facing_heading_degrees(int32_t *heading_degrees) {
  int32_t target = target_map_bearing_centi_degrees();
  if (target >= 0) {
    int32_t display = s_map_bearing_display_centi_degrees >= 0 ?
        s_map_bearing_display_centi_degrees : target;
    *heading_degrees = rounded_degrees_from_centi(display);
    return true;
  }
  return false;
}

bool map_orientation_active(void) {
  if (s_map_orientation != 1 || s_manual_pan) {
    return false;
  }
#if defined(PBL_COMPASS)
  return compass_heading_is_valid();
#else
  return phone_heading_is_usable();
#endif
}

int32_t render_viewport_x(void) {
  return s_gps_smoothing_active ? s_render_viewport_x : s_viewport_x;
}

int32_t render_viewport_y(void) {
  return s_gps_smoothing_active ? s_render_viewport_y : s_viewport_y;
}

int32_t display_gps_world_x(void) {
  return s_gps_smoothing_active ? s_gps_display_world_x : s_gps_world_x;
}

int32_t display_gps_world_y(void) {
  return s_gps_smoothing_active ? s_gps_display_world_y : s_gps_world_y;
}

static int32_t gps_abs_i32(int32_t value) {
  return value < 0 ? -value : value;
}

static int32_t gps_approx_distance_px(int32_t dx, int32_t dy) {
  int32_t ax = gps_abs_i32(dx);
  int32_t ay = gps_abs_i32(dy);
  int32_t major = ax > ay ? ax : ay;
  int32_t minor = ax > ay ? ay : ax;
  return major + (minor / 2);
}

static int32_t gps_smoothing_elapsed_ms(int32_t previous_elapsed_ms,
                                        int32_t next_elapsed_ms,
                                        time_t previous_received_at) {
  if (previous_elapsed_ms >= 0 && next_elapsed_ms >= previous_elapsed_ms) {
    return next_elapsed_ms - previous_elapsed_ms;
  }

  time_t now = time(NULL);
  if (previous_received_at > 0 && now >= previous_received_at) {
    int32_t elapsed_ms = (int32_t)(now - previous_received_at) * 1000;
    return elapsed_ms > 0 ? elapsed_ms : GPS_SMOOTHING_DEFAULT_INTERVAL_MS;
  }
  return GPS_SMOOTHING_DEFAULT_INTERVAL_MS;
}

static int active_smoothing_travel_mode(bool *navigating_out) {
  bool navigating = has_active_route();
  if (navigating_out) {
    *navigating_out = navigating;
  }
  int mode = navigating ? s_active_route_mode : s_travel_mode;
  if (mode < TRAVEL_MODE_WALK || mode > TRAVEL_MODE_DRIVE) {
    mode = TRAVEL_MODE_DRIVE;
  }
  return mode;
}

static int32_t gps_smoothing_distance_limit_px(int32_t elapsed_ms) {
  if (elapsed_ms < 0) {
    elapsed_ms = GPS_SMOOTHING_DEFAULT_INTERVAL_MS;
  }
  if (elapsed_ms > GPS_SMOOTHING_MAX_INTERVAL_MS) {
    elapsed_ms = GPS_SMOOTHING_MAX_INTERVAL_MS;
  }

  bool navigating = false;
  int mode = active_smoothing_travel_mode(&navigating);
  int32_t base_px = 20;
  int32_t rate_px_per_s = 45;
  int32_t cap_px = navigating ? 192 : 256;
  if (mode == TRAVEL_MODE_WALK) {
    base_px = 8;
    rate_px_per_s = 3;
    cap_px = navigating ? 36 : 48;
  } else if (mode == TRAVEL_MODE_BIKE) {
    base_px = 12;
    rate_px_per_s = 10;
    cap_px = navigating ? 96 : 128;
  }

  int32_t limit = base_px +
      (int32_t)(((int64_t)rate_px_per_s * elapsed_ms) / 1000);
  return limit > cap_px ? cap_px : limit;
}

bool gps_smoothing_should_animate(bool had_gps, int32_t previous_world_x,
                                  int32_t previous_world_y,
                                  int32_t next_world_x,
                                  int32_t next_world_y,
                                  int32_t previous_elapsed_ms,
                                  int32_t next_elapsed_ms,
                                  time_t previous_received_at,
                                  int32_t *distance_px_out) {
  if (!had_gps) {
    return false;
  }

  int32_t dx = next_world_x - previous_world_x;
  int32_t dy = next_world_y - previous_world_y;
  int32_t distance_px = gps_approx_distance_px(dx, dy);
  if (distance_px_out) {
    *distance_px_out = distance_px;
  }
  if (distance_px <= 0) {
    return false;
  }

  int32_t elapsed_ms = gps_smoothing_elapsed_ms(previous_elapsed_ms,
                                               next_elapsed_ms,
                                               previous_received_at);
  int32_t limit_px = gps_smoothing_distance_limit_px(elapsed_ms);
  return distance_px <= limit_px;
}

static uint16_t gps_smoothing_duration_for_distance(int32_t distance_px) {
  int32_t duration = GPS_SMOOTHING_MIN_DURATION_MS +
      distance_px * GPS_SMOOTHING_DURATION_PER_PX_MS;
  if (duration > GPS_SMOOTHING_MAX_DURATION_MS) {
    duration = GPS_SMOOTHING_MAX_DURATION_MS;
  }
  return (uint16_t)duration;
}

static int32_t lerp_i32_q8(int32_t start, int32_t target, uint16_t progress_q8) {
  if (progress_q8 >= 256) {
    return target;
  }
  return start + (int32_t)(((int64_t)(target - start) * progress_q8) / 256);
}

static uint16_t gps_smoothing_elapsed_since_start_ms(void) {
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  int32_t elapsed = (int32_t)(now_s - s_gps_smoothing_started_s) * 1000 +
      (int32_t)now_ms - (int32_t)s_gps_smoothing_started_ms;
  if (elapsed < 0) {
    return 0;
  }
  if (elapsed > UINT16_MAX) {
    return UINT16_MAX;
  }
  return (uint16_t)elapsed;
}

static void update_gps_smoothing_display(void) {
  uint16_t duration = s_gps_smoothing_duration_ms;
  uint16_t elapsed = gps_smoothing_elapsed_since_start_ms();
  uint16_t progress_q8 = (elapsed >= duration || duration == 0) ? 256 :
      (uint16_t)(((uint32_t)elapsed * 256) / duration);
  uint16_t eased_q8 = tile_animation_eased_q8(progress_q8);

  s_gps_display_world_x = lerp_i32_q8(s_gps_smoothing_start_world_x,
                                      s_gps_smoothing_target_world_x,
                                      eased_q8);
  s_gps_display_world_y = lerp_i32_q8(s_gps_smoothing_start_world_y,
                                      s_gps_smoothing_target_world_y,
                                      eased_q8);
  s_render_viewport_x = lerp_i32_q8(s_gps_smoothing_start_viewport_x,
                                    s_gps_smoothing_target_viewport_x,
                                    eased_q8);
  s_render_viewport_y = lerp_i32_q8(s_gps_smoothing_start_viewport_y,
                                    s_gps_smoothing_target_viewport_y,
                                    eased_q8);

  if (progress_q8 >= 256) {
    s_gps_smoothing_active = false;
    s_gps_smoothing_mode = GPS_SMOOTHING_NONE;
    s_gps_display_world_x = s_gps_world_x;
    s_gps_display_world_y = s_gps_world_y;
    s_render_viewport_x = s_viewport_x;
    s_render_viewport_y = s_viewport_y;
  }
}

void complete_gps_smoothing(void) {
  s_gps_smoothing_active = false;
  s_gps_smoothing_mode = GPS_SMOOTHING_NONE;
  s_gps_display_world_x = s_gps_world_x;
  s_gps_display_world_y = s_gps_world_y;
  s_render_viewport_x = s_viewport_x;
  s_render_viewport_y = s_viewport_y;
  release_visual_animation_tick_if_idle();
}

void start_gps_smoothing(uint8_t mode, int32_t start_world_x,
                         int32_t start_world_y,
                         int32_t start_viewport_x,
                         int32_t start_viewport_y,
                         int32_t distance_px) {
  if (mode == GPS_SMOOTHING_MAP && !map_orientation_active()) {
    mode = GPS_SMOOTHING_LOCATION;
  }
  if (mode != GPS_SMOOTHING_MAP && mode != GPS_SMOOTHING_LOCATION) {
    complete_gps_smoothing();
    return;
  }
  if (distance_px <= 0) {
    complete_gps_smoothing();
    return;
  }
  s_gps_smoothing_active = true;
  s_gps_smoothing_mode = mode;
  time_ms(&s_gps_smoothing_started_s, &s_gps_smoothing_started_ms);
  s_gps_smoothing_duration_ms =
      gps_smoothing_duration_for_distance(distance_px);

  s_gps_smoothing_start_world_x = start_world_x;
  s_gps_smoothing_start_world_y = start_world_y;
  s_gps_smoothing_target_world_x = s_gps_world_x;
  s_gps_smoothing_target_world_y = s_gps_world_y;
  s_gps_display_world_x = start_world_x;
  s_gps_display_world_y = start_world_y;

  if (mode == GPS_SMOOTHING_MAP) {
    s_gps_smoothing_start_viewport_x = start_viewport_x;
    s_gps_smoothing_start_viewport_y = start_viewport_y;
  } else {
    s_gps_smoothing_start_viewport_x = s_viewport_x;
    s_gps_smoothing_start_viewport_y = s_viewport_y;
  }
  s_gps_smoothing_target_viewport_x = s_viewport_x;
  s_gps_smoothing_target_viewport_y = s_viewport_y;
  s_render_viewport_x = s_gps_smoothing_start_viewport_x;
  s_render_viewport_y = s_gps_smoothing_start_viewport_y;
  schedule_visual_animation_tick();
}

bool gps_smoothing_animation_active(void) {
  return s_gps_smoothing_active;
}

bool advance_gps_smoothing(void) {
  if (!s_gps_smoothing_active) {
    return false;
  }
  int32_t previous_world_x = s_gps_display_world_x;
  int32_t previous_world_y = s_gps_display_world_y;
  int32_t previous_viewport_x = s_render_viewport_x;
  int32_t previous_viewport_y = s_render_viewport_y;
  if (s_gps_smoothing_mode == GPS_SMOOTHING_MAP &&
      !map_orientation_active()) {
    complete_gps_smoothing();
  } else {
    update_gps_smoothing_display();
  }
  return previous_world_x != s_gps_display_world_x ||
      previous_world_y != s_gps_display_world_y ||
      previous_viewport_x != s_render_viewport_x ||
      previous_viewport_y != s_render_viewport_y;
}

int32_t active_map_bearing_degrees(void) {
  return rounded_degrees_from_centi(active_map_bearing_centi_degrees());
}

int32_t active_map_bearing_centi_degrees(void) {
  if (!map_orientation_active()) {
    return 0;
  }
  if (s_map_bearing_display_centi_degrees >= 0) {
    return normalize_centi_degrees(s_map_bearing_display_centi_degrees);
  }
  int32_t target = target_map_bearing_centi_degrees();
  return target >= 0 ? target : 0;
}

int32_t active_map_bearing_angle(void) {
  return trig_angle_from_centi_degrees(active_map_bearing_centi_degrees());
}

void cancel_map_bearing_smoothing(void) {
  if (s_map_bearing_display_centi_degrees >= 0) {
    s_map_bearing_target_centi_degrees =
        s_map_bearing_display_centi_degrees;
  }
  release_visual_animation_tick_if_idle();
}

bool map_bearing_smoothing_active(void) {
  return s_map_bearing_target_centi_degrees >= 0 &&
      s_map_bearing_display_centi_degrees >= 0 &&
      bearing_smoothing_shortest_delta(s_map_bearing_display_centi_degrees,
                                       s_map_bearing_target_centi_degrees) != 0;
}

bool sync_map_bearing_smoothing(bool animate) {
  int32_t previous_display = s_map_bearing_display_centi_degrees;
  int32_t target = target_map_bearing_centi_degrees();
  if (target < 0) {
    s_map_bearing_target_centi_degrees = target;
    s_map_bearing_display_centi_degrees = target;
    release_visual_animation_tick_if_idle();
    return previous_display != s_map_bearing_display_centi_degrees;
  }

  if (s_manual_pan) {
    animate = false;
  }
  target = normalize_centi_degrees(target);
  s_map_bearing_target_centi_degrees = target;
  if (s_map_bearing_display_centi_degrees < 0 || !animate) {
    s_map_bearing_display_centi_degrees = target;
    release_visual_animation_tick_if_idle();
    return previous_display != s_map_bearing_display_centi_degrees;
  }

  if (bearing_smoothing_shortest_delta(
          s_map_bearing_display_centi_degrees, target) == 0) {
    s_map_bearing_display_centi_degrees = target;
    release_visual_animation_tick_if_idle();
    return previous_display != s_map_bearing_display_centi_degrees;
  }

  schedule_visual_animation_tick();
  return false;
}

bool advance_map_bearing_smoothing(void) {
  if (s_map_bearing_target_centi_degrees < 0 ||
      s_map_bearing_display_centi_degrees < 0) {
    return false;
  }

  int32_t delta = bearing_smoothing_shortest_delta(
      s_map_bearing_display_centi_degrees,
      s_map_bearing_target_centi_degrees);
  if (delta == 0) {
    return false;
  }
  s_map_bearing_display_centi_degrees = bearing_smoothing_advance(
      s_map_bearing_display_centi_degrees,
      s_map_bearing_target_centi_degrees,
      bearing_reacquire_active());

  update_map_after_bearing_display_change(true);
  return true;
}

void world_delta_to_screen_delta(int32_t dx, int32_t dy,
                                        int32_t *screen_dx, int32_t *screen_dy) {
  int32_t bearing_centi = active_map_bearing_centi_degrees();
  if (bearing_centi == 0) {
    *screen_dx = dx;
    *screen_dy = dy;
    return;
  }

  int32_t angle = active_map_bearing_angle();
  int32_t sin_value = sin_lookup(angle);
  int32_t cos_value = cos_lookup(angle);
  *screen_dx = trig_ratio_to_int((int64_t)dx * cos_value +
                                 (int64_t)dy * sin_value);
  *screen_dy = trig_ratio_to_int(-(int64_t)dx * sin_value +
                                 (int64_t)dy * cos_value);
}

void screen_delta_to_world_delta(int32_t screen_dx, int32_t screen_dy,
                                        int32_t *world_dx, int32_t *world_dy) {
  int32_t bearing_centi = active_map_bearing_centi_degrees();
  if (bearing_centi == 0) {
    *world_dx = screen_dx;
    *world_dy = screen_dy;
    return;
  }

  int32_t angle = active_map_bearing_angle();
  int32_t sin_value = sin_lookup(angle);
  int32_t cos_value = cos_lookup(angle);
  *world_dx = trig_ratio_to_int((int64_t)screen_dx * cos_value -
                                (int64_t)screen_dy * sin_value);
  *world_dy = trig_ratio_to_int((int64_t)screen_dx * sin_value +
                                (int64_t)screen_dy * cos_value);
}

GPoint screen_point_from_viewport_world(int32_t world_x, int32_t world_y) {
  int32_t screen_dx;
  int32_t screen_dy;
  world_delta_to_screen_delta(world_x - render_viewport_x(),
                              world_y - render_viewport_y(),
                              &screen_dx, &screen_dy);
  screen_dx = screen_dx * s_transient_zoom_scale_q8 / TRANSIENT_SCALE_Q8_ONE;
  screen_dy = screen_dy * s_transient_zoom_scale_q8 / TRANSIENT_SCALE_Q8_ONE;
  return GPoint((int16_t)clamp_i32_to_i16((s_screen_bounds.size.w / 2) + screen_dx),
                (int16_t)clamp_i32_to_i16((s_screen_bounds.size.h / 2) + screen_dy));
}

int16_t scaled_length(int16_t value) {
  int32_t scaled = (int32_t)value * s_transient_zoom_scale_q8 / TRANSIENT_SCALE_Q8_ONE;
  if (scaled < 1) {
    return 1;
  }
  if (scaled > 32767) {
    return 32767;
  }
  return (int16_t)scaled;
}

GPoint point_from_heading(GPoint origin, int32_t heading_degrees, int16_t length) {
  int32_t angle = TRIG_MAX_ANGLE * normalize_degrees(heading_degrees) / 360;
  int32_t dx = trig_ratio_to_int((int64_t)sin_lookup(angle) * length);
  int32_t dy = -trig_ratio_to_int((int64_t)cos_lookup(angle) * length);
  return GPoint((int16_t)clamp_i32_to_i16(origin.x + dx),
                (int16_t)clamp_i32_to_i16(origin.y + dy));
}

#if defined(PBL_COMPASS)
void update_compass_heading(CompassHeadingData heading_data) {
  uint32_t now_ms = compass_now_ms();
  CompassFilterStatus status = compass_filter_status_from_pebble(
      heading_data.compass_status);
  int16_t heading = (status == CompassFilterStatusCalibrating ||
                     status == CompassFilterStatusCalibrated) ?
      (int16_t)compass_heading_to_degrees(heading_data.magnetic_heading) : -1;
  CompassFilterResult result = compass_filter_process(
      &s_compass_filter, status, heading, now_ms);
  apply_compass_filter_result(result, now_ms);
}

void compass_heading_handler(CompassHeadingData heading_data) {
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  if (s_debug_compass_override_active) {
    return;
  }
#endif
  update_compass_heading(heading_data);
}

static void compass_peek(void) {
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  if (s_debug_compass_override_active) {
    return;
  }
#endif
  CompassHeadingData heading_data = {0};
  heading_data.compass_status = compass_service_peek(&heading_data);
  update_compass_heading(heading_data);
}

void start_compass_service(void) {
  uint32_t now_ms = compass_now_ms();
  compass_filter_reset(&s_compass_filter, now_ms);
  s_compass_focused = true;
  compass_service_set_heading_filter(
      TRIG_MAX_ANGLE * COMPASS_HEADING_FILTER_DEGREES / 360);
  compass_service_subscribe(compass_heading_handler);
  app_focus_service_subscribe(compass_focus_handler);
  compass_peek();
  refresh_compass_health_monitoring();
}

void stop_compass_service(void) {
  if (s_compass_health_timer) {
    app_timer_cancel(s_compass_health_timer);
    s_compass_health_timer = NULL;
  }
  cancel_compass_outlier_timer();
  app_focus_service_unsubscribe();
  compass_service_unsubscribe();
}
#else
void start_compass_service(void) {
}

void stop_compass_service(void) {
}

void refresh_compass_health_monitoring(void) {
}

const char *compass_prompt_text(void) {
  return NULL;
}

void emit_compass_state_diagnostic(void) {
}
#endif
