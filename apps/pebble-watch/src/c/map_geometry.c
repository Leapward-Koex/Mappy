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

static int32_t shortest_centi_delta(int32_t from_centi, int32_t to_centi) {
  int32_t delta = normalize_centi_degrees(to_centi - from_centi);
  if (delta > 18000) {
    delta -= 36000;
  }
  return delta;
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

static void mark_map_dirty_for_bearing_change(void) {
  if (map_orientation_active()) {
    if (orientation_tile_coverage_changed()) {
      update_state_after_map_change();
      queue_visible_tiles();
    }
  }
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

static int32_t map_bearing_smoothing_step_centi_degrees(int32_t abs_delta) {
  int32_t step = abs_delta / MAP_BEARING_SMOOTHING_STEP_DIVISOR;
  if (step < MAP_BEARING_SMOOTHING_MIN_STEP_CENTI_DEGREES) {
    step = MAP_BEARING_SMOOTHING_MIN_STEP_CENTI_DEGREES;
  }
  if (step > MAP_BEARING_SMOOTHING_MAX_STEP_CENTI_DEGREES) {
    step = MAP_BEARING_SMOOTHING_MAX_STEP_CENTI_DEGREES;
  }
  return step;
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
  if (s_gps_smoothing_timer) {
    app_timer_cancel(s_gps_smoothing_timer);
    s_gps_smoothing_timer = NULL;
  }
  s_gps_smoothing_active = false;
  s_gps_smoothing_mode = GPS_SMOOTHING_NONE;
  s_gps_display_world_x = s_gps_world_x;
  s_gps_display_world_y = s_gps_world_y;
  s_render_viewport_x = s_viewport_x;
  s_render_viewport_y = s_viewport_y;
}

static void schedule_gps_smoothing_tick(void) {
  if (!s_gps_smoothing_timer && s_gps_smoothing_active) {
    s_gps_smoothing_timer = app_timer_register(GPS_SMOOTHING_TICK_MS,
                                               gps_smoothing_timer_callback,
                                               NULL);
  }
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
  if (s_gps_smoothing_timer) {
    app_timer_cancel(s_gps_smoothing_timer);
    s_gps_smoothing_timer = NULL;
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
  schedule_gps_smoothing_tick();
}

void gps_smoothing_timer_callback(void *data) {
  (void)data;
  s_gps_smoothing_timer = NULL;
  if (!s_gps_smoothing_active) {
    return;
  }
  if (s_gps_smoothing_mode == GPS_SMOOTHING_MAP &&
      !map_orientation_active()) {
    complete_gps_smoothing();
  } else {
    update_gps_smoothing_display();
  }
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  schedule_gps_smoothing_tick();
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
  if (s_map_bearing_smoothing_timer) {
    app_timer_cancel(s_map_bearing_smoothing_timer);
    s_map_bearing_smoothing_timer = NULL;
  }
}

static void schedule_map_bearing_smoothing(void) {
  if (!s_map_bearing_smoothing_timer) {
    s_map_bearing_smoothing_timer = app_timer_register(
        MAP_BEARING_SMOOTHING_TICK_MS, map_bearing_smoothing_timer_callback,
        NULL);
  }
}

void sync_map_bearing_smoothing(bool animate) {
  int32_t target = target_map_bearing_centi_degrees();
  if (target < 0) {
    cancel_map_bearing_smoothing();
    s_map_bearing_target_centi_degrees = target;
    s_map_bearing_display_centi_degrees = target;
    return;
  }

  if (s_manual_pan) {
    animate = false;
  }
  target = normalize_centi_degrees(target);
  s_map_bearing_target_centi_degrees = target;
  if (s_map_bearing_display_centi_degrees < 0 || !animate) {
    s_map_bearing_display_centi_degrees = target;
    cancel_map_bearing_smoothing();
    return;
  }

  if (shortest_centi_delta(s_map_bearing_display_centi_degrees, target) == 0) {
    s_map_bearing_display_centi_degrees = target;
    cancel_map_bearing_smoothing();
    return;
  }

  schedule_map_bearing_smoothing();
}

void map_bearing_smoothing_timer_callback(void *data) {
  (void)data;
  s_map_bearing_smoothing_timer = NULL;
  if (s_map_bearing_target_centi_degrees < 0 ||
      s_map_bearing_display_centi_degrees < 0) {
    cancel_map_bearing_smoothing();
    return;
  }

  int32_t delta = shortest_centi_delta(s_map_bearing_display_centi_degrees,
                                       s_map_bearing_target_centi_degrees);
  int32_t abs_delta = delta < 0 ? -delta : delta;
  int32_t step = map_bearing_smoothing_step_centi_degrees(abs_delta);
  if (abs_delta <= step) {
    s_map_bearing_display_centi_degrees =
        normalize_centi_degrees(s_map_bearing_target_centi_degrees);
  } else if (delta > 0) {
    s_map_bearing_display_centi_degrees = normalize_centi_degrees(
        s_map_bearing_display_centi_degrees + step);
  } else {
    s_map_bearing_display_centi_degrees = normalize_centi_degrees(
        s_map_bearing_display_centi_degrees - step);
  }

  mark_map_dirty_for_bearing_change();
  if (shortest_centi_delta(s_map_bearing_display_centi_degrees,
                           s_map_bearing_target_centi_degrees) != 0) {
    schedule_map_bearing_smoothing();
  }
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

GPoint screen_point_from_world(int32_t world_x, int32_t world_y, int8_t source_zoom) {
  return screen_point_from_viewport_world(
      scale_world_to_zoom(world_x, source_zoom, s_viewport_zoom),
      scale_world_to_zoom(world_y, source_zoom, s_viewport_zoom));
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
  if (heading_data.compass_status == CompassStatusDataInvalid) {
    bool was_orientation_active = map_orientation_active();
    if (s_compass_heading_degrees != -1) {
      s_compass_magnetic_degrees = -1;
      s_compass_heading_degrees = -1;
      sync_map_bearing_smoothing(false);
      if (was_orientation_active) {
        invalidate_orientation_tile_coverage();
        update_state_after_map_change();
        queue_visible_tiles();
      }
      if (s_map_layer) {
        layer_mark_dirty(s_map_layer);
      }
    }
    return;
  }

  int32_t next_magnetic_heading =
      compass_heading_to_degrees(heading_data.magnetic_heading);
  int32_t next_heading = corrected_compass_heading_degrees(next_magnetic_heading);
  if (next_heading == s_compass_heading_degrees) {
    s_compass_magnetic_degrees = next_magnetic_heading;
    return;
  }

  s_compass_magnetic_degrees = next_magnetic_heading;
  s_compass_heading_degrees = next_heading;
  sync_map_bearing_smoothing(true);
  if (map_orientation_active()) {
    if (orientation_tile_coverage_changed()) {
      update_state_after_map_change();
      queue_visible_tiles();
    } else {
      send_next_tile_request();
    }
  }
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void compass_heading_handler(CompassHeadingData heading_data) {
  update_compass_heading(heading_data);
}

void start_compass_service(void) {
  compass_service_subscribe(compass_heading_handler);
  compass_service_set_heading_filter(
      TRIG_MAX_ANGLE * COMPASS_HEADING_FILTER_DEGREES / 360);
}

void stop_compass_service(void) {
  compass_service_unsubscribe();
}
#else
void start_compass_service(void) {
}

void stop_compass_service(void) {
}
#endif
