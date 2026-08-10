#include "mappy.h"

// Visible tile queueing and AppMessage tile request dispatch.

void queue_visible_tiles(void) {
  if (!s_has_gps || s_screen_bounds.size.w == 0 || s_screen_bounds.size.h == 0) {
    return;
  }

  clear_offscreen_pending_tile_requests();
  if (s_request_index < s_request_count) {
    schedule_tile_request_watchdog();
    send_next_tile_request();
    return;
  }

  s_request_count = 0;
  s_request_index = 0;
  TileRequest origins[TILE_CACHE_SIZE];
  int origin_count = visible_tile_origins(origins, active_tile_cache_size());
  if (map_orientation_active()) {
    remember_orientation_tile_origins(origins, origin_count);
  } else {
    invalidate_orientation_tile_coverage();
  }

  for (int i = 0; i < origin_count; i++) {
    TileRequest origin = origins[i];
    TileCacheEntry *entry = find_tile(origin.world_x, origin.world_y, origin.zoom);
    if (entry && (entry->valid || entry->pending)) {
      continue;
    }
    if (s_request_count >= TILE_CACHE_SIZE) {
      continue;
    }

    TileSlotDiagnostics slot_diag;
    entry = allocate_tile_slot_with_diagnostics(origin.world_x, origin.world_y,
                                                origin.zoom, &slot_diag);
    if (!entry) {
      APP_LOG(APP_LOG_LEVEL_DEBUG,
              "Tile req defer x=%ld y=%ld z=%d slot=%s pending=%d cache=%d/%d",
              (long)origin.world_x, (long)origin.world_y, (int)origin.zoom,
              slot_diag.reason, any_pending_tile_requests() ? 1 : 0,
              active_tile_cache_size(), TILE_CACHE_SIZE);
      continue;
    }
    APP_LOG(APP_LOG_LEVEL_DEBUG,
            "Tile req x=%ld y=%ld z=%d reason=missing slot=%s old=%ld,%ld,%d oldv=%d oldp=%d q=%d cache=%d/%d vp=%ld,%ld",
            (long)origin.world_x, (long)origin.world_y, (int)origin.zoom,
            slot_diag.reason, (long)slot_diag.old_world_x,
            (long)slot_diag.old_world_y, (int)slot_diag.old_zoom,
            slot_diag.old_valid ? 1 : 0, slot_diag.old_pending ? 1 : 0,
            s_request_count + 1, active_tile_cache_size(), TILE_CACHE_SIZE,
            (long)s_viewport_x, (long)s_viewport_y);
    mark_tile_pending(entry);
    entry->valid = false;
    entry->animation_active = false;
    entry->animation_mode = TILE_ANIMATION_NONE;
    entry->last_used = ++s_access_counter;
    s_request_queue[s_request_count++] = origin;
  }

  for (int i = 1; i < s_request_count; i++) {
    TileRequest request = s_request_queue[i];
    int32_t request_center_x = request.world_x + (s_tile_width / 2);
    int32_t request_center_y = request.world_y + (s_tile_height / 2);
    int64_t request_distance =
        (int64_t)(request_center_x - s_viewport_x) * (request_center_x - s_viewport_x) +
        (int64_t)(request_center_y - s_viewport_y) * (request_center_y - s_viewport_y);
    int j = i - 1;
    while (j >= 0) {
      TileRequest prior = s_request_queue[j];
      int32_t prior_center_x = prior.world_x + (s_tile_width / 2);
      int32_t prior_center_y = prior.world_y + (s_tile_height / 2);
      int64_t prior_distance =
          (int64_t)(prior_center_x - s_viewport_x) * (prior_center_x - s_viewport_x) +
          (int64_t)(prior_center_y - s_viewport_y) * (prior_center_y - s_viewport_y);
      if (prior_distance <= request_distance) {
        break;
      }
      s_request_queue[j + 1] = prior;
      j--;
    }
    s_request_queue[j + 1] = request;
  }

  schedule_tile_request_watchdog();
  send_next_tile_request();
}

void send_next_tile_request(void) {
  if (s_outbox_busy) {
    return;
  }

  while (s_request_index < s_request_count) {
    TileRequest request = s_request_queue[s_request_index++];
    TileCacheEntry *entry = find_tile(request.world_x, request.world_y, request.zoom);
    if (!entry || entry->valid || !entry->pending) {
      continue;
    }
    if (!tile_coordinates_visible(request.world_x, request.world_y, request.zoom)) {
      clear_tile_pending(entry);
      entry->animation_active = false;
      entry->animation_mode = TILE_ANIMATION_NONE;
      continue;
    }

    DictionaryIterator *iter;
    AppMessageResult result = send_message_begin(&iter, CMD_TILE_REQUEST);
    if (result != APP_MSG_OK) {
      APP_LOG(APP_LOG_LEVEL_WARNING,
              "Tile request begin failed x=%ld y=%ld z=%d result=%d",
              (long)request.world_x, (long)request.world_y, (int)request.zoom,
              (int)result);
      TileCacheEntry *failed = find_tile(request.world_x, request.world_y, request.zoom);
      if (failed && !failed->valid) {
        clear_tile_pending(failed);
        failed->animation_active = false;
        failed->animation_mode = TILE_ANIMATION_NONE;
      }
      return;
    }

    s_inflight_request = request;
    int32_t request_id = s_next_request_id++;
    if (request_id <= 0 || s_next_request_id <= 0) {
      request_id = 1;
      s_next_request_id = 2;
    }
    entry->pending_request_id = request_id;
    write_i32(iter, MESSAGE_KEY_world_x, request.world_x);
    write_i32(iter, MESSAGE_KEY_world_y, request.world_y);
    write_i32(iter, MESSAGE_KEY_tile_zoom, request.zoom);
    write_i32(iter, MESSAGE_KEY_is_color, s_theme_mode);
    write_i32(iter, MESSAGE_KEY_request_id, request_id);
    APP_LOG(APP_LOG_LEVEL_DEBUG, "Tile request send x=%ld y=%ld z=%d idx=%d/%d",
            (long)request.world_x, (long)request.world_y, (int)request.zoom,
            s_request_index, s_request_count);
    app_message_outbox_send();
    return;
  }

  if (visible_grid_has_missing_tiles() && !any_pending_tile_requests()) {
    queue_visible_tiles();
  }
}
