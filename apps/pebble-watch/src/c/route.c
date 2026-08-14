#include "mappy.h"

// Route geometry, detail-window requests, nav steps, and GPS progress.

static void reset_turn_haptic_alerts(void);

void clear_route_detail(void) {
  s_route_detail_point_count = 0;
  s_route_detail_zoom = ROUTE_WORLD_ZOOM;
  s_route_detail_generation = 0;
  s_route_detail_center_x = 0;
  s_route_detail_center_y = 0;
  s_route_detail_width = 0;
  s_route_detail_height = 0;
  s_route_detail_window_valid = false;
  s_route_window_request_inflight = false;
  s_route_window_request_pending = false;
}

bool route_detail_window_covers_viewport(void) {
  if (!s_route_detail_window_valid ||
      s_route_detail_generation != s_route_generation ||
      s_route_detail_width <= 0 || s_route_detail_height <= 0 ||
      s_screen_bounds.size.w == 0 || s_screen_bounds.size.h == 0) {
    return false;
  }

  int32_t center_x = scale_world_to_zoom(s_viewport_x, s_viewport_zoom,
                                         ROUTE_WORLD_ZOOM);
  int32_t center_y = scale_world_to_zoom(s_viewport_y, s_viewport_zoom,
                                         ROUTE_WORLD_ZOOM);
  int32_t visible_w = scale_world_to_zoom(s_screen_bounds.size.w,
                                          s_viewport_zoom, ROUTE_WORLD_ZOOM);
  int32_t visible_h = scale_world_to_zoom(s_screen_bounds.size.h,
                                          s_viewport_zoom, ROUTE_WORLD_ZOOM);
  if (visible_w < 0) {
    visible_w = -visible_w;
  }
  if (visible_h < 0) {
    visible_h = -visible_h;
  }

  int32_t loaded_min_x = s_route_detail_center_x - (s_route_detail_width / 2);
  int32_t loaded_max_x = s_route_detail_center_x + (s_route_detail_width / 2);
  int32_t loaded_min_y = s_route_detail_center_y - (s_route_detail_height / 2);
  int32_t loaded_max_y = s_route_detail_center_y + (s_route_detail_height / 2);
  return center_x - (visible_w / 2) >= loaded_min_x &&
         center_x + (visible_w / 2) <= loaded_max_x &&
         center_y - (visible_h / 2) >= loaded_min_y &&
         center_y + (visible_h / 2) <= loaded_max_y;
}

bool route_detail_available_for_draw(void) {
  return s_viewport_zoom >= ROUTE_DETAIL_MIN_ZOOM &&
      s_route_detail_point_count > 1 &&
      s_route_detail_zoom == ROUTE_WORLD_ZOOM &&
      route_detail_window_covers_viewport();
}

void update_state_after_map_change(void) {
  if (!s_has_gps) {
    if (s_state != AppStateSetupRequired) {
      s_state = AppStateWaitingForPhone;
      set_bottom_text(MAPPY_WAITING_TEXT);
    }
    return;
  }

  if (s_route_point_count > 1) {
    s_state = AppStateNavigating;
    if (s_instruction[0] != '\0') {
      if (s_active_route_mode == 0 || s_active_route_mode == 1) {
        snprintf(s_bottom_text, sizeof(s_bottom_text), "%s\nPath limited", s_instruction);
      } else {
        set_bottom_text(s_instruction);
      }
    } else if (s_active_route_mode == 0 || s_active_route_mode == 1) {
      set_bottom_text("Route ready\nPath limited");
    } else {
      set_bottom_text("Route ready");
    }
    maybe_request_route_window();
    return;
  }

  if (visible_grid_is_complete()) {
    s_state = AppStateMapReady;
    set_bottom_text("");
  } else if (s_state != AppStateSetupRequired && s_state != AppStateRouteError) {
    s_state = AppStateMapLoading;
    set_bottom_text("Loading map");
  }
}

void clear_route_local(void) {
  s_route_generation++;
  clear_route_detail();
  s_route_point_count = 0;
  s_route_total_progress_px = 0;
  s_nav_total_steps = 0;
  s_nav_first_global_index = 0;
  s_nav_step_count = 0;
  s_current_nav_local_index = 0;
  s_next_nav_request_index = 0;
  s_last_route_progress = ROUTE_PROGRESS_UNKNOWN;
  s_nav_request_inflight = false;
  s_route_projection_unavailable_logged = false;
  s_route_offroute_logged = false;
  s_route_gps_stale_logged = false;
  reset_turn_haptic_alerts();
  s_last_walk_start_feedback_generation = INT32_MIN;
  s_route_clear_pending = false;
  s_route_applied_pending = false;
  s_route_complete_pending = false;
  s_route_steps_expected = false;
  s_active_route_request_id = 0;
  s_deferred_route_request_slot = DEFERRED_ROUTE_REQUEST_NONE;
  memset(s_nav_step_progress, 0, sizeof(s_nav_step_progress));
  s_instruction[0] = '\0';
  s_pending_route_mode = s_travel_mode;
  s_pending_route_slot = -1;
  s_active_route_slot = -1;
  s_active_route_mode = s_travel_mode;
  s_route_clear_armed = false;
  update_state_after_map_change();
  refresh_motion_detection_service();
}


bool maybe_request_route_window(void) {
  if (s_route_point_count < 2 || s_viewport_zoom < ROUTE_DETAIL_MIN_ZOOM ||
      s_screen_bounds.size.w == 0 || s_screen_bounds.size.h == 0 ||
      s_active_route_request_id <= 0) {
    s_route_window_request_pending = false;
    return false;
  }
  if (route_detail_window_covers_viewport()) {
    s_route_window_request_pending = false;
    return false;
  }
  if (s_route_window_request_inflight) {
    return false;
  }
  if (s_outbox_busy) {
    s_route_window_request_pending = true;
    return false;
  }

  int32_t center_x = scale_world_to_zoom(s_viewport_x, s_viewport_zoom,
                                         ROUTE_WORLD_ZOOM);
  int32_t center_y = scale_world_to_zoom(s_viewport_y, s_viewport_zoom,
                                         ROUTE_WORLD_ZOOM);
  int32_t visible_w = scale_world_to_zoom(s_screen_bounds.size.w,
                                          s_viewport_zoom, ROUTE_WORLD_ZOOM);
  int32_t visible_h = scale_world_to_zoom(s_screen_bounds.size.h,
                                          s_viewport_zoom, ROUTE_WORLD_ZOOM);
  if (visible_w < 0) {
    visible_w = -visible_w;
  }
  if (visible_h < 0) {
    visible_h = -visible_h;
  }
  int32_t window_w = visible_w * ROUTE_WINDOW_PREFETCH_SCREENS;
  int32_t window_h = visible_h * ROUTE_WINDOW_PREFETCH_SCREENS;
  if (window_w < ROUTE_WINDOW_MIN_SIZE) {
    window_w = ROUTE_WINDOW_MIN_SIZE;
  }
  if (window_h < ROUTE_WINDOW_MIN_SIZE) {
    window_h = ROUTE_WINDOW_MIN_SIZE;
  }

  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, CMD_ROUTE_WINDOW_REQUEST);
  if (result != APP_MSG_OK) {
    s_route_window_request_pending = true;
    return false;
  }

  write_i32(iter, MESSAGE_KEY_world_x, center_x);
  write_i32(iter, MESSAGE_KEY_world_y, center_y);
  write_i32(iter, MESSAGE_KEY_tile_zoom, s_viewport_zoom);
  write_i32(iter, MESSAGE_KEY_width, window_w);
  write_i32(iter, MESSAGE_KEY_height, window_h);
  write_i32(iter, MESSAGE_KEY_total_bytes, s_route_generation);
  write_i32(iter, MESSAGE_KEY_request_id, s_active_route_request_id);
  result = app_message_outbox_send();
  if (result != APP_MSG_OK) {
    s_outbox_busy = false;
    s_outbox_cmd = 0;
    s_route_window_request_pending = true;
    return false;
  }

  s_route_window_request_inflight = true;
  s_route_window_request_pending = false;
  APP_LOG(APP_LOG_LEVEL_DEBUG,
          "Route window request gen=%ld center=%ld,%ld z=%d size=%ldx%ld",
          (long)s_route_generation, (long)center_x, (long)center_y,
          (int)s_viewport_zoom, (long)window_w, (long)window_h);
  return true;
}

int32_t abs_i32_local(int32_t value) {
  return value < 0 ? -value : value;
}

int32_t saturating_add_i32(int32_t a, int32_t b) {
  if (b > 0 && a > INT32_MAX - b) {
    return INT32_MAX;
  }
  return a + b;
}

int32_t approx_segment_length_px(int32_t dx, int32_t dy) {
  int32_t ax = abs_i32_local(dx);
  int32_t ay = abs_i32_local(dy);
  int32_t major = ax > ay ? ax : ay;
  int32_t minor = ax > ay ? ay : ax;
  return major + (minor / 2);
}

int32_t compute_route_total_progress_px(void) {
  int32_t total_px = 0;
  for (uint16_t i = 1; i < s_route_point_count; i++) {
    int32_t dx = s_route_points[i].world_x - s_route_points[i - 1].world_x;
    int32_t dy = s_route_points[i].world_y - s_route_points[i - 1].world_y;
    total_px = saturating_add_i32(total_px, approx_segment_length_px(dx, dy));
  }
  return total_px;
}

RouteProjection project_route_points_position(const RoutePoint *points,
                                              uint16_t point_count,
                                              int32_t world_x,
                                              int32_t world_y) {
  RouteProjection best = {
    .valid = false,
    .progress_px = 0,
    .distance_sq = INT64_MAX,
    .segment_index = 0,
    .segment_t_q16 = 0,
  };
  if (!points || point_count < 2) {
    return best;
  }

  int32_t cumulative_px = 0;
  for (uint16_t i = 1; i < point_count; i++) {
    int64_t ax = points[i - 1].world_x;
    int64_t ay = points[i - 1].world_y;
    int64_t dx = (int64_t)points[i].world_x - ax;
    int64_t dy = (int64_t)points[i].world_y - ay;
    int64_t len_sq = dx * dx + dy * dy;
    int32_t segment_px = approx_segment_length_px((int32_t)dx, (int32_t)dy);
    if (len_sq <= 0 || segment_px <= 0) {
      continue;
    }

    int64_t px = (int64_t)world_x - ax;
    int64_t py = (int64_t)world_y - ay;
    int64_t dot = px * dx + py * dy;
    int64_t t_q16 = 0;
    if (dot >= len_sq) {
      t_q16 = 65536;
    } else if (dot > 0) {
      t_q16 = (dot * 65536) / len_sq;
    }

    int64_t projected_x = ax + ((dx * t_q16) / 65536);
    int64_t projected_y = ay + ((dy * t_q16) / 65536);
    int64_t off_x = (int64_t)world_x - projected_x;
    int64_t off_y = (int64_t)world_y - projected_y;
    int64_t distance_sq = off_x * off_x + off_y * off_y;
    int32_t segment_progress = (int32_t)(((int64_t)segment_px * t_q16) / 65536);
    int32_t progress_px = saturating_add_i32(cumulative_px, segment_progress);

    if (!best.valid || distance_sq < best.distance_sq) {
      best.valid = true;
      best.progress_px = progress_px;
      best.distance_sq = distance_sq;
      best.segment_index = i - 1;
      best.segment_t_q16 = (uint32_t)t_q16;
    }
    cumulative_px = saturating_add_i32(cumulative_px, segment_px);
  }
  return best;
}

RouteProjection project_route_position(int32_t world_x, int32_t world_y) {
  return project_route_points_position(s_route_points, s_route_point_count,
                                       world_x, world_y);
}

void recompute_nav_step_progress(void) {
  for (uint8_t i = 0; i < MAX_NAV_STEPS; i++) {
    s_nav_step_progress[i] = ROUTE_PROGRESS_UNKNOWN;
  }
  if (s_route_point_count < 2 || s_nav_step_count == 0) {
    return;
  }

  for (uint8_t i = 0; i < s_nav_step_count; i++) {
    RouteProjection projection =
        project_route_position(s_nav_steps[i].start_world_x, s_nav_steps[i].start_world_y);
    if (projection.valid) {
      s_nav_step_progress[i] = projection.progress_px;
    } else if (!s_route_projection_unavailable_logged) {
      s_route_projection_unavailable_logged = true;
      send_log_event(5, i, 0, "nav progress unavailable");
    }
  }
}

static int32_t clamp_threshold_px(int64_t threshold, int32_t fallback_px) {
  if (threshold <= 0) {
    return fallback_px > 0 ? fallback_px : 1;
  }
  return threshold > INT32_MAX ? INT32_MAX : (int32_t)threshold;
}

static int32_t route_meters_to_px(int32_t meters, int32_t fallback_px) {
  if (meters <= 0) {
    return fallback_px;
  }

  if (s_route_total_progress_px > 0 && s_nav_step_count > 0 &&
      s_nav_steps[0].remaining_m > 0) {
    int32_t base_progress = s_nav_step_progress[0] == ROUTE_PROGRESS_UNKNOWN
        ? 0 : s_nav_step_progress[0];
    int32_t remaining_px = s_route_total_progress_px - base_progress;
    if (remaining_px <= 0) {
      remaining_px = s_route_total_progress_px;
    }
    int64_t threshold = ((int64_t)meters * remaining_px +
                         (s_nav_steps[0].remaining_m - 1)) /
        s_nav_steps[0].remaining_m;
    return clamp_threshold_px(threshold, fallback_px);
  }
  return fallback_px;
}

int32_t route_progress_threshold_px(uint8_t local_index, int32_t meters,
                                            int32_t fallback_px) {
  if (meters <= 0) {
    return fallback_px;
  }

  if (local_index + 1 < s_nav_step_count) {
    int32_t current_px = s_nav_step_progress[local_index];
    int32_t next_px = s_nav_step_progress[local_index + 1];
    int32_t step_px = next_px - current_px;
    int32_t step_m = (int32_t)s_nav_steps[local_index].remaining_m -
                     (int32_t)s_nav_steps[local_index + 1].remaining_m;
    if (current_px != ROUTE_PROGRESS_UNKNOWN && next_px != ROUTE_PROGRESS_UNKNOWN &&
        step_px > 0 && step_m > 0) {
      int64_t threshold = ((int64_t)meters * step_px + (step_m - 1)) / step_m;
      return clamp_threshold_px(threshold, fallback_px);
    }
  }

  return route_meters_to_px(meters, fallback_px);
}

static void reset_turn_haptic_alerts(void) {
  s_turn_preview_alerted_global_index = ROUTE_TURN_ALERT_NONE;
  s_turn_now_alerted_global_index = ROUTE_TURN_ALERT_NONE;
}

static int32_t turn_preview_threshold_meters(void) {
  switch (s_active_route_mode) {
    case TRAVEL_MODE_WALK:
      return ROUTE_TURN_PREVIEW_WALK_METERS;
    case TRAVEL_MODE_BIKE:
      return ROUTE_TURN_PREVIEW_BIKE_METERS;
    default:
      return ROUTE_TURN_PREVIEW_DRIVE_METERS;
  }
}

static int32_t turn_now_threshold_meters(void) {
  switch (s_active_route_mode) {
    case TRAVEL_MODE_WALK:
      return ROUTE_TURN_NOW_WALK_METERS;
    case TRAVEL_MODE_BIKE:
      return ROUTE_TURN_NOW_BIKE_METERS;
    default:
      return ROUTE_TURN_NOW_DRIVE_METERS;
  }
}

static int32_t turn_alert_threshold_px(uint8_t target_index,
                                       int32_t meters,
                                       int32_t fallback_px) {
  if (target_index > 0) {
    return route_progress_threshold_px((uint8_t)(target_index - 1),
                                       meters, fallback_px);
  }
  return route_meters_to_px(meters, fallback_px);
}

static bool nav_step_is_final_arrival(uint8_t local_index) {
  return s_nav_total_steps > 0 &&
      (uint16_t)s_nav_steps[local_index].global_index + 1 >= s_nav_total_steps;
}

static bool next_turn_alert_target(int32_t progress, uint8_t *target_index) {
  if (s_nav_total_steps == 0 || s_nav_step_count == 0) {
    return false;
  }

  int32_t now_px = turn_alert_threshold_px(0, turn_now_threshold_meters(),
                                           ROUTE_TURN_FALLBACK_NOW_PX);
  for (uint8_t i = 0; i < s_nav_step_count; i++) {
    if (s_nav_steps[i].global_index == 0 || nav_step_is_final_arrival(i)) {
      continue;
    }
    int32_t target_progress = s_nav_step_progress[i];
    if (target_progress == ROUTE_PROGRESS_UNKNOWN) {
      continue;
    }
    if (i > 0) {
      now_px = turn_alert_threshold_px(i, turn_now_threshold_meters(),
                                       ROUTE_TURN_FALLBACK_NOW_PX);
    }
    if (target_progress < progress &&
        s_turn_now_alerted_global_index == (int16_t)s_nav_steps[i].global_index) {
      continue;
    }
    if (target_progress + now_px < progress) {
      continue;
    }
    *target_index = i;
    return true;
  }
  return false;
}

static void enqueue_turn_preview_vibration(void) {
  static const uint32_t segments[] = {80, 80, 80};
  vibes_enqueue_custom_pattern((VibePattern) {
    .durations = segments,
    .num_segments = ARRAY_LENGTH(segments),
  });
}

static void enqueue_turn_now_vibration(void) {
  static const uint32_t segments[] = {180, 80, 260};
  vibes_enqueue_custom_pattern((VibePattern) {
    .durations = segments,
    .num_segments = ARRAY_LENGTH(segments),
  });
}

static void enqueue_arrival_vibration(void) {
  static const uint32_t segments[] = {180, 80, 180, 80, 320};
  vibes_enqueue_custom_pattern((VibePattern) {
    .durations = segments,
    .num_segments = ARRAY_LENGTH(segments),
  });
}

static bool route_destination_reached(RouteProjection gps_projection,
                                      int32_t progress) {
  if (!gps_projection.valid || s_route_point_count < 2 ||
      s_route_total_progress_px <= 0) {
    return false;
  }

  int32_t arrival_px = route_meters_to_px(ROUTE_ARRIVAL_METERS,
                                          ROUTE_ARRIVAL_FALLBACK_PX);
  if (arrival_px < ROUTE_ARRIVAL_FALLBACK_PX) {
    arrival_px = ROUTE_ARRIVAL_FALLBACK_PX;
  }

  int32_t remaining_px = s_route_total_progress_px - progress;
  if (remaining_px <= arrival_px) {
    return true;
  }

  RoutePoint destination = s_route_points[s_route_point_count - 1];
  int64_t dx = (int64_t)s_gps_world_x - destination.world_x;
  int64_t dy = (int64_t)s_gps_world_y - destination.world_y;
  int64_t arrival_sq = (int64_t)arrival_px * arrival_px;
  return dx * dx + dy * dy <= arrival_sq;
}

static void finish_route_at_destination(void) {
  if (s_arrival_dialog_visible || s_route_point_count < 2) {
    return;
  }

  enqueue_arrival_vibration();
  cancel_menu_highlight_animation();
  complete_tile_animations();
  cancel_tile_redraw();
  s_menu_mode = MenuNone;
  s_menu_selection = 0;
  int32_t completed_request_id = s_active_route_request_id;
  clear_route_local();
  s_active_route_request_id = completed_request_id;
  s_arrival_dialog_visible = true;
  pause_map_bearing_rendering();
  s_route_complete_pending = true;
  s_route_clear_armed = false;
  copy_bounded_text(s_top_text, sizeof(s_top_text), "Map");
  set_bottom_text("");
  update_touch_subscription();
  if (!s_outbox_busy) {
    send_deferred_route_action();
  }
  set_bottom_text("");
  layer_mark_dirty(s_map_layer);
  APP_LOG(APP_LOG_LEVEL_INFO, "Route arrived and cleared");
}

static void maybe_fire_turn_haptic_alert(int32_t progress) {
  uint8_t target_index;
  if (!next_turn_alert_target(progress, &target_index)) {
    return;
  }

  int16_t global_index = (int16_t)s_nav_steps[target_index].global_index;
  int32_t target_progress = s_nav_step_progress[target_index];
  int32_t remaining_px = target_progress - progress;
  int32_t preview_px = turn_alert_threshold_px(target_index,
                                               turn_preview_threshold_meters(),
                                               ROUTE_TURN_FALLBACK_PREVIEW_PX);
  int32_t now_px = turn_alert_threshold_px(target_index,
                                           turn_now_threshold_meters(),
                                           ROUTE_TURN_FALLBACK_NOW_PX);

  if (remaining_px <= now_px && remaining_px >= -now_px) {
    if (s_turn_now_alerted_global_index != global_index) {
      s_turn_now_alerted_global_index = global_index;
      s_turn_preview_alerted_global_index = global_index;
      enqueue_turn_now_vibration();
      APP_LOG(APP_LOG_LEVEL_INFO, "Turn haptic now step=%d", (int)global_index);
    }
    return;
  }

  if (remaining_px >= 0 && remaining_px <= preview_px &&
      s_turn_preview_alerted_global_index != global_index) {
    s_turn_preview_alerted_global_index = global_index;
    enqueue_turn_preview_vibration();
    APP_LOG(APP_LOG_LEVEL_INFO, "Turn haptic preview step=%d", (int)global_index);
  }
}

void maybe_request_next_nav_chunk(void) {
  if (s_nav_request_inflight || s_nav_step_count == 0 ||
      s_next_nav_request_index >= s_nav_total_steps) {
    return;
  }

  uint8_t remaining_local = s_nav_step_count > s_current_nav_local_index ?
      (uint8_t)(s_nav_step_count - s_current_nav_local_index) : 0;
  if (s_current_nav_local_index >= s_nav_step_count - 2 || remaining_local <= 1) {
    send_nav_steps_request();
  }
}

bool gps_fresh_for_progress(void) {
  return gps_fix_fresh_for_seconds(GPS_PROGRESS_FRESH_SECONDS);
}

bool dismiss_arrival_dialog(void) {
  if (!s_arrival_dialog_visible) {
    return false;
  }
  s_arrival_dialog_visible = false;
  update_touch_subscription();
  resume_map_bearing_rendering();
  update_state_after_map_change();
  s_tile_redraw_deferred = false;
  layer_mark_dirty(s_map_layer);
  return true;
}

void update_nav_progress_from_gps(void) {
  if (!s_has_gps || s_route_point_count < 2) {
    return;
  }
  if (!gps_fresh_for_progress()) {
    if (!s_route_gps_stale_logged) {
      s_route_gps_stale_logged = true;
      send_log_event(5, s_nav_first_global_index, 0, "stale gps hold");
    }
    return;
  }

  RouteProjection gps_projection = project_route_position(s_gps_world_x, s_gps_world_y);
  if (!gps_projection.valid) {
    if (!s_route_projection_unavailable_logged) {
      s_route_projection_unavailable_logged = true;
      send_log_event(5, s_nav_first_global_index, 0, "nav progress unavailable");
    }
    return;
  }

  int32_t off_route_threshold_px = route_progress_threshold_px(
      s_current_nav_local_index, ROUTE_OFF_ROUTE_METERS, ROUTE_FALLBACK_OFF_ROUTE_PX);
  int64_t off_route_threshold_sq = (int64_t)off_route_threshold_px * off_route_threshold_px;
  if (gps_projection.distance_sq > off_route_threshold_sq) {
    if (!s_route_offroute_logged) {
      s_route_offroute_logged = true;
      int detail = gps_projection.distance_sq > INT32_MAX ? INT32_MAX :
          (int)gps_projection.distance_sq;
      send_log_event(7, detail, s_nav_first_global_index, "off route hold");
    }
    return;
  }
  s_route_offroute_logged = false;

  int32_t previous_progress = s_last_route_progress;
  int32_t progress = gps_projection.progress_px;
  if (route_destination_reached(gps_projection, progress)) {
    finish_route_at_destination();
    return;
  }
  if (previous_progress != ROUTE_PROGRESS_UNKNOWN && progress < previous_progress) {
    return;
  }
  if (s_nav_step_count == 0) {
    s_last_route_progress = progress;
    return;
  }
  maybe_fire_turn_haptic_alert(progress);
  if (previous_progress == ROUTE_PROGRESS_UNKNOWN) {
    s_last_route_progress = progress;
    return;
  }

  bool advanced = false;
  while (s_current_nav_local_index + 1 < s_nav_step_count) {
    int32_t current_start = s_nav_step_progress[s_current_nav_local_index];
    int32_t next_start = s_nav_step_progress[s_current_nav_local_index + 1];
    if (current_start == ROUTE_PROGRESS_UNKNOWN || next_start == ROUTE_PROGRESS_UNKNOWN ||
        next_start < current_start) {
      if (!s_route_projection_unavailable_logged) {
        s_route_projection_unavailable_logged = true;
        send_log_event(5, s_current_nav_local_index, 0, "nav progress unavailable");
      }
      break;
    }

    int32_t progress_delta = progress - previous_progress;
    int32_t advance_threshold_px = route_progress_threshold_px(
        s_current_nav_local_index, ROUTE_ADVANCE_METERS, ROUTE_FALLBACK_ADVANCE_PX);
    int32_t closer_threshold_px = route_progress_threshold_px(
        s_current_nav_local_index, ROUTE_CLOSER_METERS, ROUTE_FALLBACK_CLOSER_PX);
    if (progress - current_start < advance_threshold_px ||
        progress_delta < closer_threshold_px) {
      break;
    }

    s_current_nav_local_index++;
    copy_bounded_text(s_instruction, sizeof(s_instruction),
                      s_nav_steps[s_current_nav_local_index].instruction);
    advanced = true;
  }

  s_last_route_progress = progress;
  maybe_request_next_nav_chunk();
  if (advanced) {
    layer_mark_dirty(s_map_layer);
  }
}


void apply_route_clear(void) {
  clear_route_local();
}

void apply_route_points(DictionaryIterator *iter) {
  bool had_active_navigation = has_active_route();
  Tuple *data_tuple = dict_find(iter, MESSAGE_KEY_chunk_data);
  Tuple *generation_tuple = dict_find(iter, MESSAGE_KEY_total_bytes);
  Tuple *fresh_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  Tuple *mode_tuple = dict_find(iter, MESSAGE_KEY_is_color);
  Tuple *request_id_tuple = dict_find(iter, MESSAGE_KEY_request_id);
  Tuple *steps_expected_tuple = dict_find(iter, MESSAGE_KEY_chunk_index);
  if (!data_tuple || data_tuple->length < 3 || !request_id_tuple ||
      request_id_tuple->value->int32 <= 0) {
    return;
  }

  const uint8_t *data = data_tuple->value->data;
  uint16_t point_count = read_u16_le(data, 0);
  uint8_t header = data[2];
  uint8_t route_zoom = header & 0x7f;
  if ((header & 0x80) != 0 || route_zoom != ROUTE_WORLD_ZOOM ||
      point_count > MAX_ROUTE_POINTS) {
    set_bottom_text("Route rejected");
    send_log_event(4, route_zoom, point_count, "route rejected");
    return;
  }

  uint16_t expected_len = 3 + point_count * 8;
  if (data_tuple->length != expected_len || point_count == 1) {
    set_bottom_text("Route rejected");
    send_log_event(4, data_tuple->length, expected_len, "route rejected");
    return;
  }

  if (point_count == 0) {
    clear_route_local();
    s_state = AppStateRouteError;
    set_bottom_text("No route found");
    return;
  }

  bool dismissed_arrival_dialog = s_arrival_dialog_visible;
  s_arrival_dialog_visible = false;
  if (dismissed_arrival_dialog) {
    update_touch_subscription();
    resume_map_bearing_rendering();
  }
  bool user_visible_route = !fresh_tuple || fresh_tuple->value->int32 != 0;
  int response_route_mode = s_pending_route_mode;
  bool has_response_route_mode = false;
  if (mode_tuple) {
    int candidate_mode = mode_tuple->value->int32;
    if (candidate_mode >= TRAVEL_MODE_WALK &&
        candidate_mode <= TRAVEL_MODE_DRIVE) {
      response_route_mode = candidate_mode;
      has_response_route_mode = true;
    }
  }
  s_route_generation = generation_tuple ? generation_tuple->value->int32 :
      (s_route_generation + 1);
  s_active_route_request_id = request_id_tuple ? request_id_tuple->value->int32 : 0;
  s_route_steps_expected = steps_expected_tuple && steps_expected_tuple->value->int32 != 0;
  s_route_applied_pending = true;
  clear_route_detail();
  s_route_zoom = route_zoom;
  for (uint16_t i = 0; i < point_count; i++) {
    int offset = 3 + i * 8;
    s_route_points[i].world_x = read_i32_le(data, offset);
    s_route_points[i].world_y = read_i32_le(data, offset + 4);
  }
  s_route_point_count = point_count;
  s_route_total_progress_px = compute_route_total_progress_px();
  s_active_route_slot = (s_state == AppStateRouteLoading) ? s_pending_route_slot : -1;
  s_active_route_mode = response_route_mode;
  s_pending_route_mode = response_route_mode;
  if (has_response_route_mode && s_travel_mode != response_route_mode) {
    s_travel_mode = response_route_mode;
    persist_write_int(PERSIST_TRAVEL_MODE, s_travel_mode);
  }
  s_nav_total_steps = 0;
  s_nav_first_global_index = 0;
  s_nav_step_count = 0;
  s_current_nav_local_index = 0;
  s_next_nav_request_index = 0;
  s_last_route_progress = ROUTE_PROGRESS_UNKNOWN;
  reset_turn_haptic_alerts();
  s_nav_request_inflight = false;
  s_route_projection_unavailable_logged = false;
  s_route_offroute_logged = false;
  memset(s_nav_step_progress, 0, sizeof(s_nav_step_progress));
  s_instruction[0] = '\0';
  if (user_visible_route && s_active_route_mode == TRAVEL_MODE_WALK &&
      s_last_walk_start_feedback_generation != s_route_generation) {
    s_last_walk_start_feedback_generation = s_route_generation;
    vibes_short_pulse();
    zoom_to_max_map_level();
  }
  update_state_after_map_change();
  if (!had_active_navigation) {
    arm_route_start_bearing_reacquire();
  }
  refresh_motion_detection_service();
  if (!s_route_steps_expected) {
    send_route_applied();
  }
}

void apply_route_window_points(DictionaryIterator *iter) {
  Tuple *data_tuple = dict_find(iter, MESSAGE_KEY_chunk_data);
  Tuple *generation_tuple = dict_find(iter, MESSAGE_KEY_total_bytes);
  Tuple *center_x_tuple = dict_find(iter, MESSAGE_KEY_world_x);
  Tuple *center_y_tuple = dict_find(iter, MESSAGE_KEY_world_y);
  Tuple *zoom_tuple = dict_find(iter, MESSAGE_KEY_tile_zoom);
  Tuple *width_tuple = dict_find(iter, MESSAGE_KEY_width);
  Tuple *height_tuple = dict_find(iter, MESSAGE_KEY_height);
  Tuple *request_id_tuple = dict_find(iter, MESSAGE_KEY_request_id);
  s_route_window_request_inflight = false;
  s_route_window_request_pending = false;
  if (!data_tuple || data_tuple->length < 3 || !center_x_tuple ||
      !center_y_tuple || !zoom_tuple || !width_tuple || !height_tuple ||
      !request_id_tuple || request_id_tuple->value->int32 != s_active_route_request_id) {
    s_route_window_request_pending = true;
    send_log_event(4, 0, 0, "route window rejected");
    return;
  }

  int32_t generation = generation_tuple ? generation_tuple->value->int32 :
      s_route_generation;
  if (generation != s_route_generation) {
    s_route_window_request_pending = true;
    send_log_event(4, generation, s_route_generation, "route window stale");
    return;
  }

  const uint8_t *data = data_tuple->value->data;
  uint16_t point_count = read_u16_le(data, 0);
  uint8_t header = data[2];
  uint8_t route_zoom = header & 0x7f;
  if ((header & 0x80) != 0 || route_zoom != ROUTE_WORLD_ZOOM ||
      point_count > MAX_ROUTE_POINTS || point_count == 1) {
    s_route_window_request_pending = true;
    send_log_event(4, route_zoom, point_count, "route window rejected");
    return;
  }

  uint16_t expected_len = 3 + point_count * 8;
  if (data_tuple->length != expected_len ||
      width_tuple->value->int32 <= 0 || height_tuple->value->int32 <= 0) {
    s_route_window_request_pending = true;
    send_log_event(4, data_tuple->length, expected_len, "route window rejected");
    return;
  }

  s_route_detail_generation = generation;
  s_route_detail_center_x = center_x_tuple->value->int32;
  s_route_detail_center_y = center_y_tuple->value->int32;
  s_route_detail_width = width_tuple->value->int32;
  s_route_detail_height = height_tuple->value->int32;
  s_route_detail_zoom = route_zoom;
  s_route_detail_window_valid = true;
  for (uint16_t i = 0; i < point_count; i++) {
    int offset = 3 + i * 8;
    s_route_detail_points[i].world_x = read_i32_le(data, offset);
    s_route_detail_points[i].world_y = read_i32_le(data, offset + 4);
  }
  s_route_detail_point_count = point_count;
  APP_LOG(APP_LOG_LEVEL_DEBUG,
          "Route window points gen=%ld count=%d center=%ld,%ld size=%ldx%ld",
          (long)generation, (int)point_count, (long)s_route_detail_center_x,
          (long)s_route_detail_center_y, (long)s_route_detail_width,
          (long)s_route_detail_height);
  update_state_after_map_change();
}

void apply_nav_steps(DictionaryIterator *iter) {
  Tuple *data_tuple = dict_find(iter, MESSAGE_KEY_chunk_data);
  Tuple *generation_tuple = dict_find(iter, MESSAGE_KEY_total_bytes);
  Tuple *request_id_tuple = dict_find(iter, MESSAGE_KEY_request_id);
  if (!data_tuple || data_tuple->length < 3 || !generation_tuple ||
      generation_tuple->value->int32 != s_route_generation ||
      !request_id_tuple || request_id_tuple->value->int32 != s_active_route_request_id) {
    send_log_event(5, 0, 0, "nav stale");
    return;
  }

  const uint8_t *data = data_tuple->value->data;
  uint8_t total_steps = data[0];
  uint8_t first_global_index = data[1];
  uint8_t chunk_count = data[2];
  if (chunk_count < 1 || chunk_count > 3) {
    send_log_event(5, chunk_count, 0, "nav rejected");
    return;
  }

  int offset = 3;
  NavStep next_steps[MAX_NAV_STEPS];
  memset(next_steps, 0, sizeof(next_steps));
  for (uint8_t i = 0; i < chunk_count; i++) {
    if (offset + 14 > data_tuple->length) {
      send_log_event(5, offset, data_tuple->length, "nav truncated");
      return;
    }
    next_steps[i].global_index = data[offset++];
    next_steps[i].start_world_x = read_i32_le(data, offset);
    offset += 4;
    next_steps[i].start_world_y = read_i32_le(data, offset);
    offset += 4;
    next_steps[i].remaining_m = read_u16_le(data, offset);
    offset += 2;
    next_steps[i].remaining_s = read_u16_le(data, offset);
    offset += 2;
    uint8_t instruction_len = data[offset++];
    if (instruction_len > MAX_INSTRUCTION_BYTES || offset + instruction_len > data_tuple->length) {
      send_log_event(5, instruction_len, offset, "nav rejected");
      return;
    }
    sanitize_payload_text(next_steps[i].instruction, sizeof(next_steps[i].instruction),
                          &data[offset], instruction_len);
    offset += instruction_len;
  }
  if (offset != data_tuple->length) {
    send_log_event(5, offset, data_tuple->length, "nav rejected");
    return;
  }

  memcpy(s_nav_steps, next_steps, sizeof(s_nav_steps));
  s_nav_total_steps = total_steps;
  s_nav_first_global_index = first_global_index;
  s_nav_step_count = chunk_count;
  s_current_nav_local_index = 0;
  s_next_nav_request_index = s_nav_first_global_index + s_nav_step_count;
  s_last_route_progress = ROUTE_PROGRESS_UNKNOWN;
  s_nav_request_inflight = false;
  s_route_projection_unavailable_logged = false;
  s_route_offroute_logged = false;
  recompute_nav_step_progress();
  copy_bounded_text(s_instruction, sizeof(s_instruction), s_nav_steps[0].instruction);
  update_nav_progress_from_gps();
  update_state_after_map_change();
  if (s_route_point_count > 1) {
    s_state = AppStateNavigating;
  }
  if (s_route_applied_pending) {
    send_route_applied();
  }
}
