#include "mappy.h"

// AppMessage send/receive flow, settings sync, GPS, destinations, and errors.

#define PENDING_SETTING_THEME (1u << 0)
#define PENDING_SETTING_TRAVEL_MODE (1u << 1)
#define PENDING_SETTING_UNITS (1u << 2)
#define PENDING_SETTING_BACKLIGHT (1u << 3)
#define PENDING_SETTING_MAP_ORIENTATION (1u << 4)
#define PENDING_SETTING_TILE_ANIMATION (1u << 5)

static uint32_t s_pending_setting_mask;

static bool send_scalar_setting(int32_t cmd, int32_t value);

static uint32_t pending_setting_mask_for_cmd(int32_t cmd) {
  switch (cmd) {
    case CMD_THEME:
      return PENDING_SETTING_THEME;
    case CMD_TRAVEL_MODE:
      return PENDING_SETTING_TRAVEL_MODE;
    case CMD_UNITS:
      return PENDING_SETTING_UNITS;
    case CMD_BACKLIGHT:
      return PENDING_SETTING_BACKLIGHT;
    case CMD_MAP_ORIENTATION:
      return PENDING_SETTING_MAP_ORIENTATION;
    case CMD_TILE_ANIMATION:
      return PENDING_SETTING_TILE_ANIMATION;
    default:
      return 0;
  }
}

static void queue_scalar_setting(int32_t cmd) {
  uint32_t mask = pending_setting_mask_for_cmd(cmd);
  if (mask != 0) {
    s_pending_setting_mask |= mask;
  }
}

static bool send_pending_scalar_setting(void) {
  if (s_pending_setting_mask == 0) {
    return false;
  }

  if (s_pending_setting_mask & PENDING_SETTING_THEME) {
    s_pending_setting_mask &= ~PENDING_SETTING_THEME;
    return send_scalar_setting(CMD_THEME, s_theme_mode);
  }
  if (s_pending_setting_mask & PENDING_SETTING_TRAVEL_MODE) {
    s_pending_setting_mask &= ~PENDING_SETTING_TRAVEL_MODE;
    return send_scalar_setting(CMD_TRAVEL_MODE, s_travel_mode);
  }
  if (s_pending_setting_mask & PENDING_SETTING_UNITS) {
    s_pending_setting_mask &= ~PENDING_SETTING_UNITS;
    return send_scalar_setting(CMD_UNITS, s_units_mode);
  }
  if (s_pending_setting_mask & PENDING_SETTING_BACKLIGHT) {
    s_pending_setting_mask &= ~PENDING_SETTING_BACKLIGHT;
    return send_scalar_setting(CMD_BACKLIGHT, s_backlight_mode);
  }
  if (s_pending_setting_mask & PENDING_SETTING_MAP_ORIENTATION) {
    s_pending_setting_mask &= ~PENDING_SETTING_MAP_ORIENTATION;
    return send_scalar_setting(CMD_MAP_ORIENTATION, s_map_orientation);
  }
  if (s_pending_setting_mask & PENDING_SETTING_TILE_ANIMATION) {
    s_pending_setting_mask &= ~PENDING_SETTING_TILE_ANIMATION;
    return send_scalar_setting(CMD_TILE_ANIMATION, s_tile_animation_mode);
  }

  s_pending_setting_mask = 0;
  return false;
}

void queue_log_event(int category, int detail, int detail2, const char *text) {
  uint8_t index = 0;
  if (s_pending_log_count >= LOG_EVENT_QUEUE_SIZE) {
    index = s_pending_log_head;
    s_pending_log_head = (s_pending_log_head + 1) % LOG_EVENT_QUEUE_SIZE;
    s_pending_log_count--;
    if (s_pending_log_overflow_count < UINT16_MAX) {
      s_pending_log_overflow_count++;
    }
  } else {
    index = (s_pending_log_head + s_pending_log_count) % LOG_EVENT_QUEUE_SIZE;
  }

  s_pending_log_events[index].pending = true;
  s_pending_log_events[index].category = category;
  s_pending_log_events[index].detail = detail;
  s_pending_log_events[index].detail2 = detail2;
  copy_bounded_text(s_pending_log_events[index].text, sizeof(s_pending_log_events[index].text), text);
  s_pending_log_count++;
}

bool dequeue_log_event(PendingLogEvent *event) {
  if (!event) {
    return false;
  }
  if (s_pending_log_overflow_count > 0) {
    uint16_t dropped = s_pending_log_overflow_count;
    s_pending_log_overflow_count = 0;
    event->pending = true;
    event->category = 5;
    event->detail = dropped;
    event->detail2 = LOG_EVENT_QUEUE_SIZE;
    copy_bounded_text(event->text, sizeof(event->text), "diagnostic overflow");
    return true;
  }
  if (s_pending_log_count == 0) {
    return false;
  }

  *event = s_pending_log_events[s_pending_log_head];
  s_pending_log_events[s_pending_log_head].pending = false;
  s_pending_log_head = (s_pending_log_head + 1) % LOG_EVENT_QUEUE_SIZE;
  s_pending_log_count--;
  return event->pending;
}

bool send_log_event(int category, int detail, int detail2, const char *text) {
  if (s_outbox_busy) {
    queue_log_event(category, detail, detail2, text);
    return false;
  }

  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, CMD_LOG_EVENT);
  if (result != APP_MSG_OK) {
    queue_log_event(category, detail, detail2, text);
    return false;
  }

  write_i32(iter, MESSAGE_KEY_button_id, category);
  write_i32(iter, MESSAGE_KEY_chunk_offset, detail);
  write_i32(iter, MESSAGE_KEY_chunk_index, detail2);
  if (text && text[0] != '\0') {
    char capped[MAX_INSTRUCTION_BYTES + 1];
    copy_bounded_text(capped, sizeof(capped), text);
    dict_write_cstring(iter, MESSAGE_KEY_instruction, capped);
  }
  result = app_message_outbox_send();
  if (result != APP_MSG_OK) {
    s_outbox_busy = false;
    s_outbox_cmd = 0;
    queue_log_event(category, detail, detail2, text);
    return false;
  }
  return true;
}


AppMessageResult send_message_begin(DictionaryIterator **iter, int32_t cmd) {
  if (s_outbox_busy) {
    return APP_MSG_BUSY;
  }

  AppMessageResult result = app_message_outbox_begin(iter);
  if (result != APP_MSG_OK) {
    return result;
  }

  write_i32(*iter, MESSAGE_KEY_cmd, cmd);
  s_outbox_cmd = cmd;
  s_outbox_busy = true;
  return APP_MSG_OK;
}


void send_init(void) {
  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, CMD_INIT);
  if (result != APP_MSG_OK) {
    APP_LOG(APP_LOG_LEVEL_WARNING, "CMD_INIT begin failed: %d", (int)result);
    return;
  }

  write_i32(iter, MESSAGE_KEY_tile_zoom, s_theme_mode);
  write_i32(iter, MESSAGE_KEY_button_id, s_travel_mode);
  write_i32(iter, MESSAGE_KEY_total_bytes, s_backlight_mode);
  write_i32(iter, MESSAGE_KEY_chunk_offset, s_map_orientation);
  app_message_outbox_send();
  s_state = AppStateWaitingForPhone;
  set_bottom_text(MAPPY_WAITING_TEXT);
}

void send_zoom_button(int delta) {
  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, CMD_BUTTON);
  if (result != APP_MSG_OK) {
    return;
  }

  write_i32(iter, MESSAGE_KEY_button_id, delta);
  write_i32(iter, MESSAGE_KEY_is_color, s_theme_mode);
  app_message_outbox_send();
}

static bool is_saved_destination_id(int slot) {
  return slot >= 0 && slot <= MAX_SAVED_DESTINATION_ID;
}

void send_route_request(void) {
  int request_slot = s_selected_slot;
  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, CMD_ROUTE_REQUEST);
  if (result != APP_MSG_OK) {
    s_deferred_route_request_slot = request_slot;
    set_bottom_text("Route queued");
    layer_mark_dirty(s_map_layer);
    return;
  }

  if (is_saved_destination_id(request_slot)) {
    write_i32(iter, MESSAGE_KEY_button_id, request_slot);
  }
  write_i32(iter, MESSAGE_KEY_is_color, s_travel_mode);
  s_pending_route_mode = s_travel_mode;
  s_pending_route_slot = is_saved_destination_id(request_slot) ? request_slot : -1;
  result = app_message_outbox_send();
  if (result != APP_MSG_OK) {
    s_outbox_busy = false;
    s_outbox_cmd = 0;
    s_deferred_route_request_slot = request_slot;
    set_bottom_text("Route queued");
    layer_mark_dirty(s_map_layer);
    return;
  }
  s_state = AppStateRouteLoading;
  set_bottom_text("Finding route");
  layer_mark_dirty(s_map_layer);
}

void send_route_clear(void) {
  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, CMD_ROUTE_CLEAR);
  if (result != APP_MSG_OK) {
    s_route_clear_pending = true;
    set_bottom_text("Clear queued");
    layer_mark_dirty(s_map_layer);
    return;
  }
  result = app_message_outbox_send();
  if (result != APP_MSG_OK) {
    s_outbox_busy = false;
    s_outbox_cmd = 0;
    s_route_clear_pending = true;
    set_bottom_text("Clear queued");
    layer_mark_dirty(s_map_layer);
    return;
  }
  clear_route_local();
  layer_mark_dirty(s_map_layer);
}

bool send_deferred_route_action(void) {
  PendingLogEvent event;
  if (dequeue_log_event(&event)) {
    send_log_event(event.category, event.detail, event.detail2, event.text);
    return true;
  }
  if (s_route_clear_pending) {
    s_route_clear_pending = false;
    send_route_clear();
    return true;
  }
  if (s_deferred_route_request_slot != DEFERRED_ROUTE_REQUEST_NONE) {
    int slot = s_deferred_route_request_slot;
    s_deferred_route_request_slot = DEFERRED_ROUTE_REQUEST_NONE;
    s_selected_slot = slot;
    send_route_request();
    return true;
  }
  if (s_route_window_request_pending && maybe_request_route_window()) {
    return true;
  }
  if (send_pending_scalar_setting()) {
    return true;
  }
  return false;
}

static bool send_scalar_setting(int32_t cmd, int32_t value) {
  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, cmd);
  if (result != APP_MSG_OK) {
    queue_scalar_setting(cmd);
    return false;
  }
  write_i32(iter, MESSAGE_KEY_button_id, value);
  result = app_message_outbox_send();
  if (result != APP_MSG_OK) {
    s_outbox_busy = false;
    s_outbox_cmd = 0;
    queue_scalar_setting(cmd);
    return false;
  }
  return true;
}

void send_theme(void) {
  send_scalar_setting(CMD_THEME, s_theme_mode);
}

void send_travel_mode(void) {
  send_scalar_setting(CMD_TRAVEL_MODE, s_travel_mode);
}

void send_units(void) {
  send_scalar_setting(CMD_UNITS, s_units_mode);
}

void send_backlight(void) {
  send_scalar_setting(CMD_BACKLIGHT, s_backlight_mode);
}

void send_map_orientation(void) {
  send_scalar_setting(CMD_MAP_ORIENTATION, s_map_orientation);
}

void send_tile_animation(void) {
  send_scalar_setting(CMD_TILE_ANIMATION, s_tile_animation_mode);
}

void send_nav_steps_request(void) {
  DictionaryIterator *iter;
  AppMessageResult result = send_message_begin(&iter, CMD_NAV_STEPS);
  if (result != APP_MSG_OK) {
    return;
  }
  write_i32(iter, MESSAGE_KEY_button_id, s_next_nav_request_index);
  result = app_message_outbox_send();
  if (result != APP_MSG_OK) {
    s_outbox_busy = false;
    s_outbox_cmd = 0;
    return;
  }
  s_nav_request_inflight = true;
}


bool apply_destinations_payload(const uint8_t *data, uint16_t len) {
  if (!data || len == 0 || (data[0] & 0x80) == 0) {
    set_bottom_text("Destinations rejected");
    return false;
  }

  uint8_t count = data[0] & 0x7f;
  if (count > MAX_DESTINATION_RECORDS) {
    set_bottom_text("Too many destinations");
    return false;
  }

  DestinationSlot *next = NULL;
  if (count > 0) {
    next = calloc(count, sizeof(DestinationSlot));
    if (!next) {
      set_bottom_text("Destinations rejected");
      send_log_event(2, count, 0, "destination allocation failed");
      return false;
    }
  }
  uint16_t offset = 1;
  uint8_t next_count = 0;

  for (uint8_t i = 0; i < count; i++) {
    if (offset + 12 > len) {
      free(next);
      set_bottom_text("Destination truncated");
      return false;
    }

    uint8_t slot = data[offset++];
    uint8_t kind = data[offset++];
    uint8_t mode = data[offset++];
    int32_t latitude_e7 = read_i32_le(data, offset);
    offset += 4;
    int32_t longitude_e7 = read_i32_le(data, offset);
    offset += 4;
    uint8_t label_len = data[offset++];

    if (slot > MAX_SAVED_DESTINATION_ID || label_len > 30 || offset + label_len > len) {
      free(next);
      set_bottom_text("Destination rejected");
      send_log_event(2, slot, 0, "destination rejected");
      return false;
    }

    int target_index = -1;
    for (uint8_t existing = 0; existing < next_count; existing++) {
      if (next[existing].slot == slot) {
        target_index = existing;
        break;
      }
    }
    if (target_index >= 0) {
      send_log_event(2, slot, 0, "duplicate destination");
    } else {
      target_index = next_count++;
    }

    next[target_index].slot = slot;
    next[target_index].configured = true;
    next[target_index].kind = kind <= 2 ? kind : 2;
    next[target_index].default_travel_mode = mode <= 2 ? mode : 2;
    next[target_index].latitude_e7 = latitude_e7;
    next[target_index].longitude_e7 = longitude_e7;
    sanitize_payload_text(next[target_index].label, sizeof(next[target_index].label),
                          &data[offset], label_len);
    offset += label_len;
  }

  if (offset != len) {
    free(next);
    set_bottom_text("Destination rejected");
    return false;
  }

  free(s_destinations);
  s_destinations = next;
  s_destination_count = next_count;
  copy_bounded_text(s_top_text, sizeof(s_top_text), "Map");
  return true;
}


static bool gps_sequence_is_stale(int32_t sequence) {
  return s_has_gps_sequence && sequence <= s_gps_sequence;
}

static void apply_gps_fix(int32_t world_x, int32_t world_y, int32_t zoom,
                          int32_t heading_degrees, bool has_sequence,
                          int32_t sequence, int32_t elapsed_ms,
                          int32_t accuracy_cm, const char *provider) {
  if (has_sequence && gps_sequence_is_stale(sequence)) {
    return;
  }

  bool had_gps = s_has_gps;
  int32_t previous_world_x = s_gps_world_x;
  int32_t previous_world_y = s_gps_world_y;
  int32_t previous_elapsed_ms = s_gps_elapsed_ms;
  time_t previous_received_at = s_gps_received_at;
  int32_t previous_display_world_x = display_gps_world_x();
  int32_t previous_display_world_y = display_gps_world_y();
  int32_t previous_render_viewport_x = render_viewport_x();
  int32_t previous_render_viewport_y = render_viewport_y();

  s_gps_world_x = world_x;
  s_gps_world_y = world_y;
  s_gps_zoom = zoom;
  if (s_gps_zoom != ROUTE_WORLD_ZOOM) {
    s_gps_zoom = ROUTE_WORLD_ZOOM;
  }
  s_heading_degrees = heading_degrees;
  if (s_heading_degrees < 0 || s_heading_degrees > 360) {
    s_heading_degrees = -1;
  }
  if (has_sequence) {
    s_gps_sequence = sequence;
    s_has_gps_sequence = true;
  }
  s_gps_elapsed_ms = elapsed_ms;
  s_gps_accuracy_cm = accuracy_cm;
  copy_bounded_text(s_gps_provider, sizeof(s_gps_provider), provider);
  s_has_gps = true;
  s_gps_received_at = time(NULL);
  sync_map_bearing_smoothing(true);
  s_route_gps_stale_logged = false;
  update_touch_subscription();
  if (!s_manual_pan) {
    s_viewport_x = scale_world_to_zoom(s_gps_world_x, s_gps_zoom, s_viewport_zoom);
    s_viewport_y = scale_world_to_zoom(s_gps_world_y, s_gps_zoom, s_viewport_zoom);
  }
  int32_t gps_smoothing_distance_px = 0;
  if (gps_smoothing_should_animate(had_gps, previous_world_x, previous_world_y,
                                   s_gps_world_x, s_gps_world_y,
                                   previous_elapsed_ms, elapsed_ms,
                                   previous_received_at,
                                   &gps_smoothing_distance_px)) {
    uint8_t mode = map_orientation_active() ? GPS_SMOOTHING_MAP :
        GPS_SMOOTHING_LOCATION;
    start_gps_smoothing(mode, previous_display_world_x,
                        previous_display_world_y,
                        previous_render_viewport_x,
                        previous_render_viewport_y,
                        gps_smoothing_distance_px);
  } else {
    complete_gps_smoothing();
  }
  copy_bounded_text(s_top_text, sizeof(s_top_text), "Map");
  update_nav_progress_from_gps();
  update_state_after_map_change();
  if (visible_grid_has_missing_tiles()) {
    queue_visible_tiles();
  } else {
    send_next_tile_request();
  }
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void apply_gps(DictionaryIterator *iter) {
  Tuple *x_tuple = dict_find(iter, MESSAGE_KEY_world_x);
  Tuple *y_tuple = dict_find(iter, MESSAGE_KEY_world_y);
  Tuple *zoom_tuple = dict_find(iter, MESSAGE_KEY_tile_zoom);
  Tuple *heading_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  Tuple *sequence_tuple = dict_find(iter, MESSAGE_KEY_gps_sequence);
  Tuple *elapsed_tuple = dict_find(iter, MESSAGE_KEY_gps_elapsed_ms);
  Tuple *accuracy_tuple = dict_find(iter, MESSAGE_KEY_gps_accuracy_cm);
  Tuple *provider_tuple = dict_find(iter, MESSAGE_KEY_gps_provider);
  if (!x_tuple || !y_tuple) {
    return;
  }

  apply_gps_fix(x_tuple->value->int32, y_tuple->value->int32,
                zoom_tuple ? zoom_tuple->value->int32 : ROUTE_WORLD_ZOOM,
                heading_tuple ? heading_tuple->value->int32 : -1,
                sequence_tuple != NULL,
                sequence_tuple ? sequence_tuple->value->int32 : 0,
                elapsed_tuple ? elapsed_tuple->value->int32 : -1,
                accuracy_tuple ? accuracy_tuple->value->int32 : -1,
                provider_tuple ? provider_tuple->value->cstring : "");
}

void apply_declination(DictionaryIterator *iter) {
  Tuple *declination_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  if (!declination_tuple) {
    return;
  }

  int32_t next_declination = declination_tuple->value->int32;
  if (next_declination < -36000 || next_declination > 36000) {
    return;
  }

  s_declination_centi_degrees = next_declination;
  s_declination_valid = true;
  int32_t previous_heading = s_compass_heading_degrees;
  bool was_orientation_active = map_orientation_active();
  refresh_corrected_compass_heading();
  if (previous_heading != s_compass_heading_degrees) {
    bool display_changed = sync_map_bearing_smoothing(true);
    if (display_changed) {
      update_map_after_bearing_display_change(was_orientation_active);
    }
    if (display_changed && s_map_layer) {
      layer_mark_dirty(s_map_layer);
    }
  }
}

void apply_debug_compass(DictionaryIterator *iter) {
  Tuple *heading_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  if (!heading_tuple) {
    return;
  }

  bool was_orientation_active = map_orientation_active();
  int32_t heading = heading_tuple->value->int32;
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  if (heading >= 0) {
    fixture_perf_begin();
  }
#endif
  if (heading < 0) {
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
    s_debug_compass_override_active = false;
#endif
    s_compass_magnetic_degrees = -1;
    s_compass_heading_degrees = -1;
    APP_LOG(APP_LOG_LEVEL_INFO, "Debug compass cleared");
  } else {
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
    s_debug_compass_override_active = true;
#endif
    s_compass_magnetic_degrees = normalize_degrees(heading);
    s_compass_heading_degrees = normalize_degrees(heading);
    APP_LOG(APP_LOG_LEVEL_INFO, "Debug compass heading=%ld", (long)s_compass_heading_degrees);
  }

  bool display_changed = sync_map_bearing_smoothing(true);
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  if (heading >= 0 && display_changed) {
    fixture_perf_bearing_immediate_step();
  }
  if (heading >= 0 && dict_find(iter, MESSAGE_KEY_width)) {
    fixture_perf_start_mixed_sources();
  }
#endif
  if (display_changed) {
    update_map_after_bearing_display_change(was_orientation_active);
  }
  if (display_changed && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  if (heading >= 0 && !display_changed) {
    fixture_perf_maybe_emit();
  }
#endif
}

void apply_debug_tile(DictionaryIterator *iter) {
  if (!s_has_gps || !s_tiles) {
    return;
  }

  Tuple *index_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  int requested_index = index_tuple ? index_tuple->value->int32 : 0;
  if (requested_index < 0) {
    requested_index = 0;
  }

  TileRequest origins[TILE_CACHE_SIZE];
  int origin_count = visible_tile_origins(origins, active_tile_cache_size());
  if (origin_count <= 0) {
    return;
  }
  if (requested_index >= origin_count) {
    requested_index = origin_count - 1;
  }

  TileRequest origin = origins[requested_index];
  TileSlotDiagnostics slot_diag;
  TileCacheEntry *entry = allocate_tile_slot_with_diagnostics(origin.world_x,
                                                              origin.world_y,
                                                              origin.zoom,
                                                              &slot_diag);
  if (!entry || !entry->decoded) {
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Debug tile unavailable index=%d originCount=%d slot=%s",
            requested_index, origin_count, slot_diag.reason);
    return;
  }

  for (int py = 0; py < s_tile_height; py++) {
    for (int px = 0; px < s_tile_width; px += 2) {
      int pixel_index = py * s_tile_width + px;
      uint8_t low = (uint8_t)(((px / 9) + (py / 9)) & 0x0f);
      uint8_t high = (uint8_t)((((px + 1) / 9) + (py / 9)) & 0x0f);
      if (px + 1 >= s_tile_width) {
        high = low;
      }
      entry->decoded[pixel_index / 2] = (uint8_t)(low | (high << 4));
    }
  }

  entry->world_x = origin.world_x;
  entry->world_y = origin.world_y;
  entry->zoom = origin.zoom;
  entry->valid = true;
  clear_tile_pending(entry);
  entry->last_used = ++s_access_counter;
  start_tile_animation(entry, true);
  update_state_after_map_change();
  APP_LOG(APP_LOG_LEVEL_INFO,
          "Debug tile accept index=%d/%d x=%ld y=%ld z=%d tile=%dx%d slot=%s",
          requested_index, origin_count, (long)origin.world_x,
          (long)origin.world_y, (int)origin.zoom, s_tile_width, s_tile_height,
          slot_diag.reason);
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

static bool route_point_at_permille(int32_t permille, int32_t *world_x,
                                    int32_t *world_y) {
  if (s_route_point_count < 2) {
    return false;
  }
  if (permille < 0) {
    permille = 0;
  } else if (permille > 1000) {
    permille = 1000;
  }

  int32_t total_progress = s_route_total_progress_px > 0 ?
      s_route_total_progress_px : compute_route_total_progress_px();
  if (total_progress <= 0) {
    *world_x = s_route_points[0].world_x;
    *world_y = s_route_points[0].world_y;
    return true;
  }

  int32_t target_progress =
      (int32_t)(((int64_t)total_progress * permille) / 1000);
  int32_t cumulative = 0;
  for (uint16_t i = 1; i < s_route_point_count; i++) {
    RoutePoint start = s_route_points[i - 1];
    RoutePoint end = s_route_points[i];
    int32_t dx = end.world_x - start.world_x;
    int32_t dy = end.world_y - start.world_y;
    int32_t segment_len = approx_segment_length_px(dx, dy);
    if (segment_len <= 0) {
      continue;
    }
    int32_t segment_end = saturating_add_i32(cumulative, segment_len);
    if (target_progress <= segment_end) {
      int32_t local_distance = target_progress - cumulative;
      if (local_distance < 0) {
        local_distance = 0;
      } else if (local_distance > segment_len) {
        local_distance = segment_len;
      }
      int32_t t_q16 =
          (int32_t)(((int64_t)local_distance * 65536) / segment_len);
      *world_x = start.world_x + (int32_t)(((int64_t)dx * t_q16) / 65536);
      *world_y = start.world_y + (int32_t)(((int64_t)dy * t_q16) / 65536);
      return true;
    }
    cumulative = segment_end;
  }

  *world_x = s_route_points[s_route_point_count - 1].world_x;
  *world_y = s_route_points[s_route_point_count - 1].world_y;
  return true;
}

void apply_debug_route_progress(DictionaryIterator *iter) {
  Tuple *progress_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  if (!progress_tuple) {
    return;
  }

  int32_t world_x;
  int32_t world_y;
  int32_t permille = progress_tuple->value->int32;
  if (!route_point_at_permille(permille, &world_x, &world_y)) {
    APP_LOG(APP_LOG_LEVEL_INFO, "Debug route progress ignored: no active route");
    send_log_event(1, CMD_DEBUG_ROUTE_PROGRESS, 0, "debug route needs route");
    return;
  }

  APP_LOG(APP_LOG_LEVEL_INFO, "Debug route progress=%ld gps=%ld,%ld",
          (long)permille, (long)world_x, (long)world_y);
  apply_gps_fix(world_x, world_y, ROUTE_WORLD_ZOOM, s_heading_degrees,
                false, 0, -1, -1, "debug");
}


void apply_travel_mode(DictionaryIterator *iter) {
  Tuple *mode_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  int next_mode = mode_tuple ? mode_tuple->value->int32 : s_travel_mode;
  if (next_mode >= 0 && next_mode <= 2) {
    s_travel_mode = next_mode;
    persist_write_int(PERSIST_TRAVEL_MODE, s_travel_mode);
  }
}


void apply_error(DictionaryIterator *iter) {
  Tuple *category_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  Tuple *failed_cmd_tuple = dict_find(iter, MESSAGE_KEY_chunk_index);
  Tuple *retry_tuple = dict_find(iter, MESSAGE_KEY_total_bytes);
  Tuple *instruction_tuple = dict_find(iter, MESSAGE_KEY_instruction);
  s_error_category = category_tuple ? category_tuple->value->int32 : 0;
  int32_t failed_cmd = failed_cmd_tuple ? failed_cmd_tuple->value->int32 : 0;
  bool retry_immediately = retry_tuple && retry_tuple->value->int32 == 1;
  if (failed_cmd == CMD_NAV_STEPS) {
    s_nav_request_inflight = false;
  }

  const char *text = instruction_tuple ? instruction_tuple->value->cstring : NULL;
  if (!text || text[0] == '\0') {
    switch (s_error_category) {
      case 1:
      case 2:
        text = "Open phone setup";
        break;
      case 3:
        text = "Waiting for GPS";
        break;
      case 4:
        text = "Network unavailable";
        break;
      case 5:
        text = "Tile unavailable";
        break;
      case 7:
        text = "No route found";
        break;
      case 8:
        text = "Destination empty";
        break;
      default:
        text = "Route unavailable";
        break;
    }
  }

  if (s_error_category == 1 || s_error_category == 2) {
    s_state = AppStateSetupRequired;
    copy_bounded_text(s_top_text, sizeof(s_top_text), "Setup required");
  } else if (s_error_category == 6 || s_error_category == 7 || s_error_category == 8) {
    s_state = AppStateRouteError;
  }
  set_bottom_text(text);

  Tuple *x_tuple = dict_find(iter, MESSAGE_KEY_world_x);
  Tuple *y_tuple = dict_find(iter, MESSAGE_KEY_world_y);
  Tuple *zoom_tuple = dict_find(iter, MESSAGE_KEY_tile_zoom);
  if (x_tuple && y_tuple && zoom_tuple) {
    TileCacheEntry *entry = find_tile(x_tuple->value->int32, y_tuple->value->int32,
                                      zoom_tuple->value->int32);
    if (entry) {
      if (failed_cmd == CMD_TILE_REQUEST && !entry->valid &&
          s_error_category != 1 && s_error_category != 2) {
        if (retry_immediately) {
          clear_tile_pending(entry);
          entry->animation_active = false;
          entry->animation_mode = TILE_ANIMATION_NONE;
          queue_visible_tiles();
        } else {
          mark_tile_pending(entry);
          schedule_tile_request_watchdog();
        }
      } else {
        clear_tile_pending(entry);
      }
    } else if (failed_cmd == CMD_TILE_REQUEST && retry_immediately &&
               s_error_category != 1 && s_error_category != 2) {
      queue_visible_tiles();
    }
  }
}

void inbox_received(DictionaryIterator *iter, void *context) {
  Tuple *cmd_tuple = dict_find(iter, MESSAGE_KEY_cmd);
  if (!cmd_tuple) {
    return;
  }

  int32_t cmd = cmd_tuple->value->int32;
  bool mark_dirty_after_dispatch = true;
  switch (cmd) {
    case CMD_GPS:
      apply_gps(iter);
      break;
    case CMD_TILE:
      apply_tile(iter);
      break;
    case CMD_THEME:
      apply_theme(iter);
      break;
    case CMD_MAP_SETTINGS:
      apply_map_settings(iter);
      break;
    case CMD_MAP_ORIENTATION:
      apply_map_orientation(iter);
      break;
    case CMD_TILE_ANIMATION:
      apply_tile_animation(iter);
      break;
    case CMD_TRAVEL_MODE:
      apply_travel_mode(iter);
      break;
    case CMD_UNITS: {
      Tuple *tuple = dict_find(iter, MESSAGE_KEY_button_id);
      int next_units = tuple ? tuple->value->int32 : s_units_mode;
      if (next_units == 0 || next_units == 1) {
        s_units_mode = next_units;
        persist_write_int(PERSIST_UNITS, s_units_mode);
        layer_mark_dirty(s_map_layer);
      }
      break;
    }
    case CMD_BACKLIGHT: {
      Tuple *tuple = dict_find(iter, MESSAGE_KEY_button_id);
      int next_backlight = tuple ? tuple->value->int32 : s_backlight_mode;
      if (next_backlight == 0 || next_backlight == 1) {
        s_backlight_mode = next_backlight;
        persist_write_int(PERSIST_BACKLIGHT, s_backlight_mode);
        light_enable(s_backlight_mode == 1);
      }
      break;
    }
    case CMD_ROUTE_POINTS:
      apply_route_points(iter);
      break;
    case CMD_ROUTE_WINDOW_POINTS:
      apply_route_window_points(iter);
      break;
    case CMD_NAV_STEPS:
      apply_nav_steps(iter);
      break;
    case CMD_ROUTE_CLEAR:
      apply_route_clear();
      break;
    case CMD_DECLINATION:
      mark_dirty_after_dispatch = false;
      apply_declination(iter);
      break;
    case CMD_DEBUG_COMPASS:
      mark_dirty_after_dispatch = false;
      apply_debug_compass(iter);
      break;
    case CMD_DEBUG_TILE:
      apply_debug_tile(iter);
      break;
    case CMD_DEBUG_ROUTE_PROGRESS:
      apply_debug_route_progress(iter);
      break;
    case CMD_ERROR_STATE:
      apply_error(iter);
      break;
    case CMD_DESTINATIONS: {
      Tuple *data_tuple = dict_find(iter, MESSAGE_KEY_chunk_data);
      if (data_tuple) {
        apply_destinations_payload(data_tuple->value->data, data_tuple->length);
      }
      break;
    }
    default:
      APP_LOG(APP_LOG_LEVEL_INFO, "Dropped unsupported command %ld", (long)cmd);
      send_log_event(1, cmd, 0, "unsupported command");
      break;
  }

  if (mark_dirty_after_dispatch && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void inbox_dropped(AppMessageResult reason, void *context) {
  APP_LOG(APP_LOG_LEVEL_WARNING, "Inbox dropped: %d", (int)reason);
  set_bottom_text("Message dropped");
  layer_mark_dirty(s_map_layer);
}

void outbox_sent(DictionaryIterator *iter, void *context) {
  s_outbox_busy = false;
  s_outbox_cmd = 0;
  if (send_deferred_route_action()) {
    return;
  }
  send_next_tile_request();
}

void outbox_failed(DictionaryIterator *iter, AppMessageResult reason, void *context) {
  APP_LOG(APP_LOG_LEVEL_WARNING, "Outbox failed cmd=%ld reason=%d", (long)s_outbox_cmd, (int)reason);
  bool should_log_tile_failure = false;
  if (s_outbox_cmd == CMD_TILE_REQUEST) {
    TileCacheEntry *entry = find_tile(s_inflight_request.world_x, s_inflight_request.world_y,
                                      s_inflight_request.zoom);
    if (entry) {
      clear_tile_pending(entry);
      entry->animation_active = false;
      entry->animation_mode = TILE_ANIMATION_NONE;
    }
    should_log_tile_failure = true;
  } else if (s_outbox_cmd == CMD_NAV_STEPS) {
    s_nav_request_inflight = false;
  } else if (s_outbox_cmd == CMD_ROUTE_CLEAR) {
    s_route_clear_pending = true;
  } else if (s_outbox_cmd == CMD_ROUTE_REQUEST) {
    s_deferred_route_request_slot = s_pending_route_slot;
  } else if (s_outbox_cmd == CMD_ROUTE_WINDOW_REQUEST) {
    s_route_window_request_inflight = false;
    s_route_window_request_pending = true;
  } else if (pending_setting_mask_for_cmd(s_outbox_cmd) != 0) {
    queue_scalar_setting(s_outbox_cmd);
  }
  s_outbox_busy = false;
  s_outbox_cmd = 0;
  if (should_log_tile_failure) {
    send_log_event(6, s_inflight_request.zoom, (int)reason, "tile request failed");
  }
  if (send_deferred_route_action()) {
    return;
  }
  send_next_tile_request();
}
