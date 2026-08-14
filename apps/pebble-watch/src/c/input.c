#include "mappy.h"

// Touch, button, menu, zoom, route action, and recenter input handling.

typedef enum {
  SettingsRowTheme,
  SettingsRowUnits,
  SettingsRowBacklight,
  SettingsRowHaptics,
  SettingsRowGlance,
  SettingsRowOrientation,
  SettingsRowTileAnimation,
  SettingsRowDiagnostics,
  SettingsRowCount,
} SettingsRow;

#define SELECT_LONG_CLICK_MS 700

void recenter_viewport(void) {
  settle_pan_motion();
  if (!s_has_gps) {
    set_bottom_text("Waiting for GPS");
    if (s_map_layer) {
      layer_mark_dirty(s_map_layer);
    }
    return;
  }
  complete_gps_smoothing();
  bool was_orientation_active = map_orientation_active();
  s_viewport_x = scale_world_to_zoom(s_gps_world_x, s_gps_zoom, s_viewport_zoom);
  s_viewport_y = scale_world_to_zoom(s_gps_world_y, s_gps_zoom, s_viewport_zoom);
  s_manual_pan = false;
  if (!was_orientation_active && map_orientation_active()) {
    s_map_bearing_display_centi_degrees = 0;
  }
  sync_map_bearing_smoothing(true);
  update_state_after_map_change();
  if (!s_tile_requests_interaction_paused) {
    queue_visible_tiles();
  }
  refresh_motion_detection_service();
  layer_mark_dirty(s_map_layer);
}


#ifdef PBL_TOUCH
static PanInertiaState s_pan_inertia;
static time_t s_pan_clock_seconds;
static uint16_t s_pan_clock_ms;
static bool s_pan_clock_valid;
static bool s_pan_settlement_pending;
static bool s_touch_teardown;

#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
static int32_t saturating_viewport_add(int32_t value, int32_t delta) {
  if (delta > 0 && value > INT32_MAX - delta) {
    return INT32_MAX;
  }
  if (delta < 0 && value < INT32_MIN - delta) {
    return INT32_MIN;
  }
  return value + delta;
}
#endif

static int32_t saturating_viewport_subtract(int32_t value, int32_t delta) {
  if (delta > 0 && value < INT32_MIN + delta) {
    return INT32_MIN;
  }
  if (delta < 0 && value > INT32_MAX + delta) {
    return INT32_MAX;
  }
  return value - delta;
}

static void reset_pan_clock(void) {
  s_pan_clock_seconds = 0;
  s_pan_clock_ms = 0;
  s_pan_clock_valid = false;
}

static void start_pan_clock(void) {
  time_ms(&s_pan_clock_seconds, &s_pan_clock_ms);
  s_pan_clock_valid = true;
}

static uint32_t consume_pan_clock_elapsed_ms(void) {
  time_t now_seconds;
  uint16_t now_ms;
  time_ms(&now_seconds, &now_ms);
  if (!s_pan_clock_valid) {
    s_pan_clock_seconds = now_seconds;
    s_pan_clock_ms = now_ms;
    s_pan_clock_valid = true;
    return 0;
  }

  int64_t elapsed =
      ((int64_t)now_seconds - (int64_t)s_pan_clock_seconds) * 1000 +
      (int32_t)now_ms - (int32_t)s_pan_clock_ms;
  s_pan_clock_seconds = now_seconds;
  s_pan_clock_ms = now_ms;
  if (elapsed <= 0) {
    return 0;
  }
  return elapsed > UINT32_MAX ? UINT32_MAX : (uint32_t)elapsed;
}

void reset_touch_state(void) {
  s_touch_active = false;
  s_transient_zoom_scale_q8 = TRANSIENT_SCALE_Q8_ONE;
}

void log_touch_disabled_once(void) {
  if (!s_touch_disabled_logged) {
    s_touch_disabled_logged = true;
    send_log_event(0, 1, 0, "touch disabled");
  }
}

void log_pinch_unavailable_once(void) {
  if (!s_pinch_unavailable_logged) {
    s_pinch_unavailable_logged = true;
    send_log_event(0, 2, 0, "pinch unavailable");
  }
}

static bool apply_pan_interaction_position(int16_t screen_x, int16_t screen_y,
                                           bool mark_dirty) {
  if (!s_touch_active) {
    return false;
  }
#ifdef MAPPY_WATCH_HARDWARE_PERF
  time_t hardware_perf_input_seconds;
  uint16_t hardware_perf_input_ms =
      time_ms(&hardware_perf_input_seconds, NULL);
#endif
  int32_t world_dx;
  int32_t world_dy;
  screen_delta_to_world_delta(screen_x - s_touch_start_x,
                              screen_y - s_touch_start_y,
                              &world_dx, &world_dy);
  int32_t next_viewport_x = saturating_viewport_subtract(
      s_touch_start_viewport_x, world_dx);
  int32_t next_viewport_y = saturating_viewport_subtract(
      s_touch_start_viewport_y, world_dy);
  bool changed = next_viewport_x != s_viewport_x ||
      next_viewport_y != s_viewport_y;
  if (changed) {
    s_viewport_x = next_viewport_x;
    s_viewport_y = next_viewport_y;
  }
  // Observe even an unchanged liftoff so a held release invalidates velocity.
  pan_inertia_observe(&s_pan_inertia, s_viewport_x, s_viewport_y,
                      consume_pan_clock_elapsed_ms());
#ifdef MAPPY_WATCH_HARDWARE_PERF
  if (changed) {
    hardware_perf_note_pan_input(hardware_perf_input_seconds,
                                 hardware_perf_input_ms);
  }
#endif
  if (changed && mark_dirty && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  return changed;
}

static bool settle_pan_motion_internal(bool mark_dirty, bool cancelled) {
  (void)cancelled;
  bool should_settle = s_pan_settlement_pending;
#ifdef MAPPY_WATCH_HARDWARE_PERF
  uint8_t inertia_ticks = s_pan_inertia.tick_count;
#endif
  pan_inertia_cancel(&s_pan_inertia);
  reset_pan_clock();
  reset_touch_state();
  if (!should_settle) {
    return false;
  }

  s_pan_settlement_pending = false;
#ifdef MAPPY_WATCH_HARDWARE_PERF
  hardware_perf_pan_settled(inertia_ticks, cancelled);
#endif
  s_manual_pan = true;
  sync_map_bearing_smoothing(false);
  update_state_after_map_change();
  resume_tile_requests_after_interaction();
  refresh_motion_detection_service();
  if (mark_dirty && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  return true;
}

static void cancel_pan_for_new_touch(void) {
#ifdef MAPPY_WATCH_HARDWARE_PERF
  if (s_pan_settlement_pending) {
    hardware_perf_pan_settled(s_pan_inertia.tick_count, true);
  }
#endif
  pan_inertia_cancel(&s_pan_inertia);
  reset_pan_clock();
  reset_touch_state();
  release_visual_animation_tick_if_idle();
}

static void finish_touch_pan(bool apply_final_position, int16_t screen_x,
                             int16_t screen_y, bool allow_inertia) {
  if (!s_touch_active) {
    return;
  }
  bool changed = false;
  if (apply_final_position) {
    changed = apply_pan_interaction_position(screen_x, screen_y, false);
  }
  reset_touch_state();
  s_manual_pan = true;
  sync_map_bearing_smoothing(false);

  bool inertia_started = allow_inertia && pan_inertia_start(&s_pan_inertia);
#ifdef MAPPY_WATCH_HARDWARE_PERF
  hardware_perf_pan_release(inertia_started);
#endif
  if (inertia_started) {
    start_pan_clock();
    schedule_visual_animation_tick();
    if (s_visual_animation_timer) {
      if (changed && s_map_layer) {
        layer_mark_dirty(s_map_layer);
      }
      return;
    }
    // AppTimer exhaustion must not leave requests paused indefinitely.
    pan_inertia_cancel(&s_pan_inertia);
  }
  settle_pan_motion_internal(true, false);
}

void begin_pan_interaction(int16_t screen_x, int16_t screen_y) {
  // A new finger takes ownership of the current coast position. Keep the tile
  // pause in force so requests are not briefly resumed between gestures.
  cancel_pan_for_new_touch();
#ifdef MAPPY_WATCH_HARDWARE_PERF
  hardware_perf_begin_pan();
#endif
  pause_tile_requests_for_interaction();
  complete_gps_smoothing();
  s_touch_active = true;
  s_touch_start_x = screen_x;
  s_touch_start_y = screen_y;
  s_touch_start_viewport_x = s_viewport_x;
  s_touch_start_viewport_y = s_viewport_y;
  s_manual_pan = true;
  s_pan_settlement_pending = true;
  pan_inertia_reset(&s_pan_inertia, s_viewport_x, s_viewport_y);
  start_pan_clock();
  refresh_motion_detection_service();
  sync_map_bearing_smoothing(false);
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void update_pan_interaction(int16_t screen_x, int16_t screen_y) {
  // Keep drag frames cheap; tile and route requests are finalized on liftoff.
  apply_pan_interaction_position(screen_x, screen_y, true);
}

void end_pan_interaction(int16_t screen_x, int16_t screen_y) {
  finish_touch_pan(true, screen_x, screen_y, true);
}

bool pan_inertia_animation_active(void) {
  return pan_inertia_is_active(&s_pan_inertia);
}

bool advance_pan_inertia_animation(void) {
  if (!pan_inertia_is_active(&s_pan_inertia)) {
    return false;
  }
  bool changed = pan_inertia_advance(&s_pan_inertia,
                                      consume_pan_clock_elapsed_ms(),
                                      &s_viewport_x, &s_viewport_y);
  if (!pan_inertia_is_active(&s_pan_inertia)) {
    // Return a changed frame for settlement too, but let the shared scheduler
    // perform the callback's single coalesced layer dirty.
    changed = settle_pan_motion_internal(false, false) || changed;
  }
  return changed;
}

void settle_pan_motion(void) {
  settle_pan_motion_internal(true, true);
  release_visual_animation_tick_if_idle();
}

void cancel_pan_motion_for_teardown(void) {
#ifdef MAPPY_WATCH_HARDWARE_PERF
  if (s_pan_settlement_pending) {
    hardware_perf_pan_settled(s_pan_inertia.tick_count, true);
  }
  hardware_perf_flush_pan();
#endif
  pan_inertia_cancel(&s_pan_inertia);
  reset_pan_clock();
  reset_touch_state();
  s_pan_settlement_pending = false;
  s_touch_teardown = true;
  if (s_touch_subscribed) {
    touch_service_unsubscribe();
    s_touch_subscribed = false;
  }
  if (s_tile_request_resume_timer) {
    app_timer_cancel(s_tile_request_resume_timer);
    s_tile_request_resume_timer = NULL;
  }
}

#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
bool fixture_start_pan_inertia(int32_t viewport_dx, int32_t viewport_dy,
                               uint16_t elapsed_ms) {
  cancel_pan_for_new_touch();
  pause_tile_requests_for_interaction();
  complete_gps_smoothing();
  s_manual_pan = true;
  s_pan_settlement_pending = true;
  pan_inertia_reset(&s_pan_inertia, s_viewport_x, s_viewport_y);
  s_viewport_x = saturating_viewport_add(s_viewport_x, viewport_dx);
  s_viewport_y = saturating_viewport_add(s_viewport_y, viewport_dy);
  pan_inertia_observe(&s_pan_inertia, s_viewport_x, s_viewport_y, elapsed_ms);
  sync_map_bearing_smoothing(false);
  refresh_motion_detection_service();
  if (!pan_inertia_start(&s_pan_inertia)) {
    settle_pan_motion_internal(true, false);
    return false;
  }

  start_pan_clock();
  schedule_visual_animation_tick();
  if (!s_visual_animation_timer) {
    pan_inertia_cancel(&s_pan_inertia);
    settle_pan_motion_internal(true, true);
    return false;
  }
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  return true;
}
#endif

void touch_handler(const TouchEvent *event, void *context) {
  if (!event || s_menu_mode != MenuNone || s_arrival_dialog_visible ||
      !touch_service_is_enabled()) {
    if (event && !touch_service_is_enabled()) {
      log_touch_disabled_once();
      settle_pan_motion();
    }
    return;
  }

  switch (event->type) {
    case TouchEvent_Touchdown:
      begin_pan_interaction(event->x, event->y);
      break;
    case TouchEvent_PositionUpdate:
      if (!s_touch_active) {
        return;
      }
      update_pan_interaction(event->x, event->y);
      break;
    case TouchEvent_Liftoff:
      if (!s_touch_active) {
        return;
      }
      // Liftoff coordinates can be newer than the last position event when the
      // event loop was busy. Apply them before ending the gesture.
      end_pan_interaction(event->x, event->y);
      break;
  }
}

void update_touch_subscription(void) {
  bool should_subscribe = !s_touch_teardown && s_menu_mode == MenuNone &&
      !s_arrival_dialog_visible && s_has_gps;
  bool touch_enabled = should_subscribe && touch_service_is_enabled();
  if (touch_enabled && !s_touch_subscribed) {
    touch_service_subscribe(touch_handler, NULL);
    s_touch_subscribed = true;
#if !MAPPY_TOUCH_PINCH_SUPPORTED
    log_pinch_unavailable_once();
#endif
  } else if ((!touch_enabled || !should_subscribe) && s_touch_subscribed) {
    // Menu/modal transitions and service loss settle the last accepted
    // position so tile dispatch cannot remain paused.
    settle_pan_motion();
    touch_service_unsubscribe();
    s_touch_subscribed = false;
    reset_touch_state();
  } else if (should_subscribe && !touch_enabled) {
    log_touch_disabled_once();
  }
}
#else
bool pan_inertia_animation_active(void) {
  return false;
}

bool advance_pan_inertia_animation(void) {
  return false;
}

void settle_pan_motion(void) {
}

void cancel_pan_motion_for_teardown(void) {
}

#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
bool fixture_start_pan_inertia(int32_t viewport_dx, int32_t viewport_dy,
                               uint16_t elapsed_ms) {
  (void)viewport_dx;
  (void)viewport_dy;
  (void)elapsed_ms;
  return false;
}
#endif

void update_touch_subscription(void) {
  s_transient_zoom_scale_q8 = TRANSIENT_SCALE_Q8_ONE;
}
#endif


bool has_active_route(void) {
  return s_route_point_count > 1 || s_state == AppStateRouteLoading;
}

void open_menu(MenuMode mode) {
  settle_pan_motion();
  bool opening_overlay = s_menu_mode == MenuNone;
  complete_tile_animations();
  s_menu_mode = mode;
  if (opening_overlay) {
    pause_map_bearing_rendering();
  }
  s_menu_selection = 0;
  reset_menu_highlight_animation();
  update_touch_subscription();
  refresh_motion_detection_service();
  layer_mark_dirty(s_map_layer);
}

void close_menu(void) {
  cancel_menu_highlight_animation();
  s_menu_mode = MenuNone;
  s_menu_selection = 0;
  update_touch_subscription();
  update_state_after_map_change();
  resume_map_bearing_rendering();
  refresh_motion_detection_service();
  s_tile_redraw_deferred = false;
  layer_mark_dirty(s_map_layer);
}

int menu_item_count(void) {
  switch (s_menu_mode) {
    case MenuDestinations:
      return s_destination_count > 0 ? s_destination_count : 1;
    case MenuTravelMode:
      return 3;
    case MenuSettings:
      return SettingsRowCount;
    case MenuActions:
      return has_active_route() ? 6 : 4;
    case MenuNone:
      return 0;
  }
  return 0;
}

const char *travel_mode_label(int mode) {
  switch (mode) {
    case 0:
      return "Walk";
    case 1:
      return "Bike";
    default:
      return "Drive";
  }
}

const char *theme_label(int mode) {
  switch (mode) {
    case 1:
      return "Day";
    case 2:
      return "Night";
    default:
      return "Auto";
  }
}

const char *orientation_label(void) {
  return s_map_orientation == 1 ? "facing" : "north";
}

const char *tile_animation_label(void) {
  switch (s_tile_animation_mode) {
    case TILE_ANIMATION_NONE:
      return "none";
    case TILE_ANIMATION_FADE_ZOOM:
      return "fade+zoom";
    case TILE_ANIMATION_FADE:
    default:
      return "fade";
  }
}

static const char *navigation_feedback_mode_label(int mode) {
  switch (navigation_feedback_normalize_mode(mode)) {
    case NavigationFeedbackModeTurns:
      return "turns";
    case NavigationFeedbackModeArrival:
      return "arrival";
    case NavigationFeedbackModeOff:
      return "off";
    case NavigationFeedbackModeAll:
    default:
      return "all";
  }
}

const char *menu_title(void) {
  switch (s_menu_mode) {
    case MenuDestinations:
      return "Destinations";
    case MenuTravelMode:
      return "Travel Mode";
    case MenuSettings:
      return "Settings";
    case MenuActions:
      return "Actions";
    case MenuNone:
      return "";
  }
  return "";
}

void menu_item_label(int index, char *buffer, size_t buffer_size) {
  buffer[0] = '\0';
  switch (s_menu_mode) {
    case MenuDestinations:
      if (s_destination_count == 0) {
        snprintf(buffer, buffer_size, "No destinations");
      } else if (index >= 0 && index < s_destination_count && s_destinations[index].configured) {
        snprintf(buffer, buffer_size, "%s", s_destinations[index].label);
      } else {
        snprintf(buffer, buffer_size, "Destination");
      }
      break;
    case MenuTravelMode: {
      const int mode_for_index[3] = {2, 0, 1};
      int mode = mode_for_index[index < 0 || index > 2 ? 0 : index];
      snprintf(buffer, buffer_size, "%s%s", mode == s_travel_mode ? "* " : "", travel_mode_label(mode));
      break;
    }
    case MenuSettings:
      if (index == SettingsRowTheme) {
        snprintf(buffer, buffer_size, "Theme %s", theme_label(s_theme_mode));
      } else if (index == SettingsRowUnits) {
        snprintf(buffer, buffer_size, "Units %s", s_units_mode == 1 ? "metric" : "imperial");
      } else if (index == SettingsRowBacklight) {
        snprintf(buffer, buffer_size, "Backlight %s", s_backlight_mode ? "on" : "auto");
      } else if (index == SettingsRowHaptics) {
        snprintf(buffer, buffer_size, "Haptics %s",
                 navigation_feedback_mode_label(s_haptic_mode));
      } else if (index == SettingsRowGlance) {
        snprintf(buffer, buffer_size, "Glance %s",
                 navigation_feedback_mode_label(s_glance_mode));
      } else if (index == SettingsRowOrientation) {
        snprintf(buffer, buffer_size, "Orient %s", orientation_label());
      } else if (index == SettingsRowTileAnimation) {
        snprintf(buffer, buffer_size, "Tile anim %s", tile_animation_label());
      } else {
        snprintf(buffer, buffer_size, "Diagnostics local");
      }
      break;
    case MenuActions:
      if (has_active_route()) {
        if (index == 0) {
          snprintf(buffer, buffer_size, "Reroute");
        } else if (index == 1) {
          snprintf(buffer, buffer_size, "Clear route");
        } else if (index == 2) {
          snprintf(buffer, buffer_size, "Next steps");
        } else if (index == 3) {
          snprintf(buffer, buffer_size, "Travel mode");
        } else if (index == 4) {
          snprintf(buffer, buffer_size, "Recenter");
        } else {
          snprintf(buffer, buffer_size, "Settings");
        }
      } else {
        if (index == 0) {
          snprintf(buffer, buffer_size, "Destinations");
        } else if (index == 1) {
          snprintf(buffer, buffer_size, "Travel mode");
        } else if (index == 2) {
          snprintf(buffer, buffer_size, "Recenter");
        } else {
          snprintf(buffer, buffer_size, "Settings");
        }
      }
      break;
    case MenuNone:
      break;
  }
}


void select_menu_item(void) {
  switch (s_menu_mode) {
    case MenuDestinations:
      if (s_destination_count == 0) {
        set_bottom_text("No destinations");
        close_menu();
        break;
      }
      if (s_menu_selection >= 0 && s_menu_selection < s_destination_count) {
        DestinationSlot *destination = &s_destinations[s_menu_selection];
        s_selected_slot = destination->slot;
        copy_bounded_text(s_top_text, sizeof(s_top_text), destination->label);
        close_menu();
        send_route_request();
      } else {
        set_bottom_text("Destination missing");
        close_menu();
      }
      break;
    case MenuTravelMode: {
      const int mode_for_index[3] = {2, 0, 1};
      int next_mode = mode_for_index[s_menu_selection < 0 || s_menu_selection > 2 ? 0 : s_menu_selection];
      bool should_refresh_active_route =
          has_active_route() && next_mode != s_active_route_mode;
      s_travel_mode = next_mode;
      persist_write_int(PERSIST_TRAVEL_MODE, s_travel_mode);
      if (should_refresh_active_route) {
        s_deferred_route_request_slot =
            (s_active_route_slot >= 0) ? s_active_route_slot : -1;
        set_bottom_text("Route queued");
        layer_mark_dirty(s_map_layer);
      }
      send_travel_mode();
      close_menu();
      break;
    }
    case MenuSettings:
      if (s_menu_selection == SettingsRowTheme) {
        s_theme_mode = (s_theme_mode + 1) % 3;
        persist_write_int(PERSIST_THEME, s_theme_mode);
        invalidate_tiles_with_reason(TileInvalidateTheme);
        queue_visible_tiles();
        send_theme();
      } else if (s_menu_selection == SettingsRowUnits) {
        s_units_mode = s_units_mode == 1 ? 0 : 1;
        persist_write_int(PERSIST_UNITS, s_units_mode);
        send_units();
      } else if (s_menu_selection == SettingsRowBacklight) {
        s_backlight_mode = s_backlight_mode == 1 ? 0 : 1;
        persist_write_int(PERSIST_BACKLIGHT, s_backlight_mode);
        light_enable(s_backlight_mode == 1);
        send_backlight();
      } else if (s_menu_selection == SettingsRowHaptics ||
                 s_menu_selection == SettingsRowGlance) {
        bool is_haptic = s_menu_selection == SettingsRowHaptics;
        int *mode = is_haptic ? &s_haptic_mode : &s_glance_mode;
        *mode = navigation_feedback_next_mode(*mode);
        persist_write_int(is_haptic ? PERSIST_HAPTIC_MODE : PERSIST_GLANCE_MODE,
                          *mode);
        if (is_haptic) {
          vibes_cancel();
          send_haptic_mode();
        } else {
          send_glance_mode();
        }
      } else if (s_menu_selection == SettingsRowOrientation) {
        complete_gps_smoothing();
        bool resume_follow_for_facing =
            s_map_orientation != 1 && s_manual_pan && s_has_gps;
        bool was_orientation_active = map_orientation_active();
        if (resume_follow_for_facing) {
          s_viewport_x = scale_world_to_zoom(s_gps_world_x, s_gps_zoom,
                                             s_viewport_zoom);
          s_viewport_y = scale_world_to_zoom(s_gps_world_y, s_gps_zoom,
                                             s_viewport_zoom);
          s_manual_pan = false;
        }
        s_map_orientation = s_map_orientation == 1 ? 0 : 1;
        persist_write_int(PERSIST_MAP_ORIENTATION, s_map_orientation);
        send_map_orientation();
        if (!was_orientation_active && map_orientation_active()) {
          s_map_bearing_display_centi_degrees = 0;
        }
        sync_map_bearing_smoothing(true);
        if (resume_follow_for_facing || was_orientation_active ||
            map_orientation_active()) {
          complete_tile_animations();
        }
        update_state_after_map_change();
        if (resume_follow_for_facing || was_orientation_active ||
            map_orientation_active()) {
          queue_visible_tiles();
        }
        refresh_motion_detection_service();
      } else if (s_menu_selection == SettingsRowTileAnimation) {
        s_tile_animation_mode = (s_tile_animation_mode + 1) % 3;
        persist_write_int(PERSIST_TILE_ANIMATION, s_tile_animation_mode);
        if (s_tile_animation_mode == TILE_ANIMATION_NONE) {
          complete_tile_animations();
        }
        send_tile_animation();
      } else if (s_menu_selection == SettingsRowDiagnostics) {
        send_log_event(4, 0, 0, "diagnostics menu");
      }
      start_menu_value_animation(1);
      layer_mark_dirty(s_map_layer);
      break;
    case MenuActions:
      if (has_active_route()) {
        if (s_menu_selection == 0) {
          close_menu();
          if (s_active_route_slot >= 0) {
            s_selected_slot = s_active_route_slot;
          } else {
            s_selected_slot = -1;
          }
          send_route_request();
        } else if (s_menu_selection == 1) {
          close_menu();
          send_route_clear();
        } else if (s_menu_selection == 2) {
          close_menu();
          send_nav_steps_request();
        } else if (s_menu_selection == 3) {
          open_menu(MenuTravelMode);
        } else if (s_menu_selection == 4) {
          close_menu();
          recenter_viewport();
        } else {
          open_menu(MenuSettings);
        }
      } else {
        if (s_menu_selection == 0) {
          open_menu(MenuDestinations);
        } else if (s_menu_selection == 1) {
          open_menu(MenuTravelMode);
        } else if (s_menu_selection == 2) {
          close_menu();
          recenter_viewport();
        } else {
          open_menu(MenuSettings);
        }
      }
      break;
    case MenuNone:
      break;
  }
}


bool set_viewport_zoom(int next_zoom, int notification_delta) {
  settle_pan_motion();
  complete_gps_smoothing();
  s_transient_zoom_scale_q8 = TRANSIENT_SCALE_Q8_ONE;
  if (next_zoom < MIN_MAP_ZOOM) {
    next_zoom = MIN_MAP_ZOOM;
  } else if (next_zoom > MAX_MAP_ZOOM) {
    next_zoom = MAX_MAP_ZOOM;
  }
  if (next_zoom == s_viewport_zoom) {
    return false;
  }

  int previous_zoom = s_viewport_zoom;
  s_viewport_x = scale_world_to_zoom(s_viewport_x, s_viewport_zoom, next_zoom);
  s_viewport_y = scale_world_to_zoom(s_viewport_y, s_viewport_zoom, next_zoom);
  s_viewport_zoom = next_zoom;
#ifdef MAPPY_WATCH_HARDWARE_PERF
  hardware_perf_begin_zoom();
#endif
  persist_write_int(PERSIST_ZOOM, s_viewport_zoom);
  complete_tile_animations();
  cancel_tile_redraw();
  cancel_all_tile_requests();
  invalidate_orientation_tile_coverage();
  begin_zoom_fallback(previous_zoom);
  update_state_after_map_change();
  if (notification_delta != 0) {
    send_zoom_button(notification_delta > 0 ? 1 : -1);
  } else {
    int delta = s_viewport_zoom - previous_zoom;
    if (delta != 0) {
      send_zoom_button(delta > 0 ? 1 : -1);
    }
  }
  if (!s_tile_requests_interaction_paused) {
    queue_visible_tiles();
  }
  layer_mark_dirty(s_map_layer);
  return true;
}

void zoom_to_max_map_level(void) {
  set_viewport_zoom(MAX_MAP_ZOOM, 1);
}

void change_zoom(int delta) {
  if (!set_viewport_zoom(s_viewport_zoom + delta, delta)) {
    send_log_event(0, s_viewport_zoom, delta, "zoom clamped");
  }
}

void up_click_handler(ClickRecognizerRef recognizer, void *context) {
  settle_pan_motion();
  if (dismiss_arrival_dialog()) {
    return;
  }
  if (s_menu_mode != MenuNone) {
    int count = menu_item_count();
    if (count > 0) {
      int previous_selection = s_menu_selection;
      s_menu_selection = (s_menu_selection + count - 1) % count;
      start_menu_highlight_animation(previous_selection, -1);
    }
    return;
  }
  s_route_clear_armed = false;
  change_zoom(1);
}

void down_click_handler(ClickRecognizerRef recognizer, void *context) {
  settle_pan_motion();
  if (dismiss_arrival_dialog()) {
    return;
  }
  if (s_menu_mode != MenuNone) {
    int count = menu_item_count();
    if (count > 0) {
      int previous_selection = s_menu_selection;
      s_menu_selection = (s_menu_selection + 1) % count;
      start_menu_highlight_animation(previous_selection, 1);
    }
    return;
  }
  s_route_clear_armed = false;
  change_zoom(-1);
}

void select_click_handler(ClickRecognizerRef recognizer, void *context) {
  settle_pan_motion();
  if (dismiss_arrival_dialog()) {
    return;
  }
  s_route_clear_armed = false;
  if (s_menu_mode != MenuNone) {
    select_menu_item();
    return;
  }
  open_menu(MenuActions);
}

void select_long_click_handler(ClickRecognizerRef recognizer, void *context) {
  if (s_menu_mode != MenuNone) {
    return;
  }
  settle_pan_motion();
  if (dismiss_arrival_dialog()) {
    return;
  }
  s_route_clear_armed = false;
  recenter_viewport();
}

void back_click_handler(ClickRecognizerRef recognizer, void *context) {
  settle_pan_motion();
  if (dismiss_arrival_dialog()) {
    return;
  }
  if (s_menu_mode != MenuNone) {
    close_menu();
    return;
  }
  if (s_route_point_count > 0 || s_state == AppStateRouteError || s_state == AppStateRouteLoading) {
    if (!s_route_clear_armed) {
      s_route_clear_armed = true;
      set_bottom_text("Back again clears route");
      layer_mark_dirty(s_map_layer);
      return;
    }
    send_route_clear();
    return;
  }
  window_stack_pop(true);
}

void click_config_provider(void *context) {
  window_single_click_subscribe(BUTTON_ID_UP, up_click_handler);
  window_single_click_subscribe(BUTTON_ID_DOWN, down_click_handler);
  window_single_click_subscribe(BUTTON_ID_SELECT, select_click_handler);
  window_long_click_subscribe(BUTTON_ID_SELECT, SELECT_LONG_CLICK_MS,
                              select_long_click_handler, NULL);
  window_single_click_subscribe(BUTTON_ID_BACK, back_click_handler);
}
