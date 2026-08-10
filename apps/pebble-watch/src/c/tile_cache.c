#include "mappy.h"

// Tile cache bookkeeping, visibility checks, and stale request cleanup.

void mark_tile_pending(TileCacheEntry *entry) {
  if (!entry) {
    return;
  }
  entry->pending = true;
  time_ms(&entry->pending_started_s, &entry->pending_started_ms);
}

void clear_tile_pending(TileCacheEntry *entry) {
  if (!entry) {
    return;
  }
  entry->pending = false;
  entry->pending_request_id = 0;
  entry->pending_started_s = 0;
  entry->pending_started_ms = 0;
}

uint16_t tile_pending_elapsed_ms(const TileCacheEntry *entry) {
  if (!entry || !entry->pending) {
    return 0;
  }
  if (entry->pending_started_s == 0 && entry->pending_started_ms == 0) {
    return UINT16_MAX;
  }

  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  int32_t elapsed = (int32_t)(now_s - entry->pending_started_s) * 1000 +
      (int32_t)now_ms - (int32_t)entry->pending_started_ms;
  if (elapsed < 0) {
    return 0;
  }
  if (elapsed > UINT16_MAX) {
    return UINT16_MAX;
  }
  return (uint16_t)elapsed;
}

bool any_pending_tile_requests(void) {
  if (!s_tiles) {
    return false;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].pending) {
      return true;
    }
  }
  return false;
}

bool expire_stale_tile_requests(void) {
  if (!s_tiles) {
    return false;
  }

  bool expired_any = false;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (!entry->pending || tile_pending_elapsed_ms(entry) < TILE_REQUEST_STALE_MS) {
      continue;
    }
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Tile pending expired x=%ld y=%ld z=%d age=%u cache=%d/%d",
            (long)entry->world_x, (long)entry->world_y, (int)entry->zoom,
            tile_pending_elapsed_ms(entry), active_tile_cache_size(), TILE_CACHE_SIZE);
    clear_tile_pending(entry);
    entry->animation_active = false;
    entry->animation_mode = TILE_ANIMATION_NONE;
    expired_any = true;
  }
  return expired_any;
}

void tile_request_watchdog_callback(void *data) {
  (void)data;
  s_tile_request_watchdog_timer = NULL;
  if (expire_stale_tile_requests()) {
    send_next_tile_request();
    if (s_map_layer) {
      layer_mark_dirty(s_map_layer);
    }
  }
  if (any_pending_tile_requests()) {
    s_tile_request_watchdog_timer = app_timer_register(TILE_REQUEST_WATCHDOG_MS,
                                                       tile_request_watchdog_callback,
                                                       NULL);
  }
}

void schedule_tile_request_watchdog(void) {
  if (!s_tile_request_watchdog_timer && any_pending_tile_requests()) {
    s_tile_request_watchdog_timer = app_timer_register(TILE_REQUEST_WATCHDOG_MS,
                                                       tile_request_watchdog_callback,
                                                       NULL);
  }
}

void cancel_tile_request_watchdog(void) {
  if (s_tile_request_watchdog_timer) {
    app_timer_cancel(s_tile_request_watchdog_timer);
    s_tile_request_watchdog_timer = NULL;
  }
}

void invalidate_tiles_with_reason(TileInvalidationReason reason) {
  complete_tile_animations();
  cancel_tile_request_watchdog();
  reset_tile_chunk_assembly();
  invalidate_orientation_tile_coverage();
  if (!s_tiles) {
    s_request_count = 0;
    s_request_index = 0;
    APP_LOG(APP_LOG_LEVEL_INFO, "Tile invalidate reason=%s cache=0/%d",
            tile_invalidation_reason_label(reason), TILE_CACHE_SIZE);
    return;
  }
  int valid_count = 0;
  int pending_count = 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].valid) {
      valid_count++;
    }
    if (s_tiles[i].pending) {
      pending_count++;
    }
    s_tiles[i].valid = false;
    clear_tile_pending(&s_tiles[i]);
    s_tiles[i].animation_active = false;
    s_tiles[i].animation_mode = TILE_ANIMATION_NONE;
  }
  s_request_count = 0;
  s_request_index = 0;
  APP_LOG(APP_LOG_LEVEL_INFO,
          "Tile invalidate reason=%s valid=%d pending=%d cache=%d/%d size=%dx%d",
          tile_invalidation_reason_label(reason), valid_count, pending_count,
          capacity, TILE_CACHE_SIZE, s_tile_width, s_tile_height);
}

bool tile_matches(const TileCacheEntry *entry, int32_t world_x, int32_t world_y, int8_t zoom) {
  return entry->world_x == world_x && entry->world_y == world_y && entry->zoom == zoom;
}

TileCacheEntry *find_tile(int32_t world_x, int32_t world_y, int8_t zoom) {
  if (!s_tiles) {
    return NULL;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if ((s_tiles[i].valid || s_tiles[i].pending) &&
        tile_matches(&s_tiles[i], world_x, world_y, zoom)) {
      return &s_tiles[i];
    }
  }
  return NULL;
}

static int32_t tile_origin_distance_sq(const TileRequest *request) {
  int32_t center_x = request->world_x + (s_tile_width / 2);
  int32_t center_y = request->world_y + (s_tile_height / 2);
  int32_t dx = center_x - s_viewport_x;
  int32_t dy = center_y - s_viewport_y;
  return dx * dx + dy * dy;
}

static bool tile_origin_precedes(const TileRequest *a, const TileRequest *b) {
  int32_t distance_a = tile_origin_distance_sq(a);
  int32_t distance_b = tile_origin_distance_sq(b);
  if (distance_a != distance_b) {
    return distance_a < distance_b;
  }
  if (a->world_y != b->world_y) {
    return a->world_y < b->world_y;
  }
  if (a->world_x != b->world_x) {
    return a->world_x < b->world_x;
  }
  return a->zoom < b->zoom;
}

static void insert_visible_tile_origin(TileRequest *origins, int *count,
                                       int max_count, int32_t world_x,
                                       int32_t world_y) {
  TileRequest request = (TileRequest) {
    .world_x = world_x,
    .world_y = world_y,
    .zoom = s_viewport_zoom,
  };
  int insert_at = *count;
  while (insert_at > 0 && tile_origin_precedes(&request, &origins[insert_at - 1])) {
    insert_at--;
  }
  if (insert_at >= max_count) {
    return;
  }

  int limit = *count < max_count ? *count : max_count - 1;
  for (int i = limit; i > insert_at; i--) {
    origins[i] = origins[i - 1];
  }
  origins[insert_at] = request;
  if (*count < max_count) {
    (*count)++;
  }
}

int visible_tile_origins(TileRequest *origins, int max_count) {
  if (!origins || max_count <= 0 || s_screen_bounds.size.w == 0 ||
      s_screen_bounds.size.h == 0) {
    return 0;
  }
  if (max_count > TILE_CACHE_SIZE) {
    max_count = TILE_CACHE_SIZE;
  }

  int count = 0;
  if (!map_orientation_active()) {
    int32_t left = s_viewport_x - (s_screen_bounds.size.w / 2);
    int32_t top = s_viewport_y - (s_screen_bounds.size.h / 2);
    int32_t start_x = floor_div_i32(left, s_tile_width) * s_tile_width;
    int32_t start_y = floor_div_i32(top, s_tile_height) * s_tile_height;
    int grid_cols = ceil_div_i32(s_screen_bounds.size.w, s_tile_width) + 1;
    int grid_rows = ceil_div_i32(s_screen_bounds.size.h, s_tile_height) + 1;
    for (int row = 0; row < grid_rows; row++) {
      for (int col = 0; col < grid_cols; col++) {
        insert_visible_tile_origin(origins, &count, max_count,
                                   start_x + col * s_tile_width,
                                   start_y + row * s_tile_height);
      }
    }
  } else {
    int32_t half_w = s_screen_bounds.size.w / 2;
    int32_t half_h = s_screen_bounds.size.h / 2;
    const int32_t screen_corners[4][2] = {
      {-1, -1}, {1, -1}, {1, 1}, {-1, 1},
    };
    int32_t min_x = INT32_MAX;
    int32_t max_x = INT32_MIN;
    int32_t min_y = INT32_MAX;
    int32_t max_y = INT32_MIN;
    for (int i = 0; i < 4; i++) {
      int32_t world_dx;
      int32_t world_dy;
      screen_delta_to_world_delta(screen_corners[i][0] * half_w,
                                  screen_corners[i][1] * half_h,
                                  &world_dx, &world_dy);
      int32_t world_x = s_viewport_x + world_dx;
      int32_t world_y = s_viewport_y + world_dy;
      if (world_x < min_x) {
        min_x = world_x;
      }
      if (world_x > max_x) {
        max_x = world_x;
      }
      if (world_y < min_y) {
        min_y = world_y;
      }
      if (world_y > max_y) {
        max_y = world_y;
      }
    }

    int32_t start_x = floor_div_i32(min_x, s_tile_width) * s_tile_width;
    int32_t end_x = floor_div_i32(max_x, s_tile_width) * s_tile_width;
    int32_t start_y = floor_div_i32(min_y, s_tile_height) * s_tile_height;
    int32_t end_y = floor_div_i32(max_y, s_tile_height) * s_tile_height;
    for (int32_t y = start_y; y <= end_y; y += s_tile_height) {
      for (int32_t x = start_x; x <= end_x; x += s_tile_width) {
        insert_visible_tile_origin(origins, &count, max_count, x, y);
      }
    }
  }

  return count;
}

void invalidate_orientation_tile_coverage(void) {
  s_orientation_tile_origin_count = 0;
  s_orientation_tile_origins_valid = false;
}

void remember_orientation_tile_origins(const TileRequest *origins, int count) {
  if (!origins || count < 0 || count > TILE_CACHE_SIZE) {
    invalidate_orientation_tile_coverage();
    return;
  }

  for (int i = 0; i < count; i++) {
    s_orientation_tile_origins[i] = origins[i];
  }
  s_orientation_tile_origin_count = count;
  s_orientation_tile_origins_valid = true;
}

bool orientation_tile_coverage_changed(void) {
  TileRequest origins[TILE_CACHE_SIZE];
  int count = visible_tile_origins(origins, active_tile_cache_size());
  bool changed = !s_orientation_tile_origins_valid ||
      count != s_orientation_tile_origin_count;
  if (!changed) {
    for (int i = 0; i < count; i++) {
      if (origins[i].world_x != s_orientation_tile_origins[i].world_x ||
          origins[i].world_y != s_orientation_tile_origins[i].world_y ||
          origins[i].zoom != s_orientation_tile_origins[i].zoom) {
        changed = true;
        break;
      }
    }
  }
  if (changed) {
    remember_orientation_tile_origins(origins, count);
  }
  return changed;
}

bool tile_coordinates_visible(int32_t world_x, int32_t world_y, int8_t zoom) {
  if (zoom != s_viewport_zoom || s_screen_bounds.size.w == 0 ||
      s_screen_bounds.size.h == 0) {
    return false;
  }

  if (!map_orientation_active()) {
    int32_t left = s_viewport_x - (s_screen_bounds.size.w / 2);
    int32_t top = s_viewport_y - (s_screen_bounds.size.h / 2);
    int32_t start_x = floor_div_i32(left, s_tile_width) * s_tile_width;
    int32_t start_y = floor_div_i32(top, s_tile_height) * s_tile_height;
    int grid_cols = ceil_div_i32(s_screen_bounds.size.w, s_tile_width) + 1;
    int grid_rows = ceil_div_i32(s_screen_bounds.size.h, s_tile_height) + 1;
    int32_t dx = world_x - start_x;
    int32_t dy = world_y - start_y;
    return dx >= 0 && dy >= 0 &&
        dx <= (grid_cols - 1) * s_tile_width &&
        dy <= (grid_rows - 1) * s_tile_height &&
        dx % s_tile_width == 0 &&
        dy % s_tile_height == 0;
  }

  TileRequest origins[TILE_CACHE_SIZE];
  int count = visible_tile_origins(origins, active_tile_cache_size());
  for (int i = 0; i < count; i++) {
    if (zoom == origins[i].zoom &&
        world_x == origins[i].world_x &&
        world_y == origins[i].world_y) {
      return true;
    }
  }
  return false;
}

bool tile_is_visible(const TileCacheEntry *entry) {
  return entry && tile_coordinates_visible(entry->world_x, entry->world_y, entry->zoom);
}

void clear_offscreen_pending_tile_requests(void) {
  if (!s_tiles) {
    return;
  }

  int cleared = 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (!entry->pending || tile_is_visible(entry)) {
      continue;
    }
    clear_tile_pending(entry);
    entry->animation_active = false;
    entry->animation_mode = TILE_ANIMATION_NONE;
    cleared++;
  }
  if (cleared > 0) {
    APP_LOG(APP_LOG_LEVEL_DEBUG, "Tile pending clear offscreen count=%d cache=%d/%d",
            cleared, capacity, TILE_CACHE_SIZE);
  }
}

void clear_unsent_tile_requests(void) {
  if (!s_tiles || s_request_index >= s_request_count) {
    return;
  }

  int cleared = 0;
  for (int i = s_request_index; i < s_request_count; i++) {
    TileRequest request = s_request_queue[i];
    TileCacheEntry *entry = find_tile(request.world_x, request.world_y, request.zoom);
    if (!entry || !entry->pending || entry->valid) {
      continue;
    }
    clear_tile_pending(entry);
    entry->animation_active = false;
    entry->animation_mode = TILE_ANIMATION_NONE;
    cleared++;
  }
  if (cleared > 0) {
    APP_LOG(APP_LOG_LEVEL_DEBUG, "Tile pending clear unsent count=%d idx=%d/%d",
            cleared, s_request_index, s_request_count);
  }
}

TileCacheEntry *allocate_tile_slot_with_diagnostics(int32_t world_x, int32_t world_y,
                                                           int8_t zoom,
                                                           TileSlotDiagnostics *diag) {
  init_tile_slot_diagnostics(diag);
  if (!s_tiles) {
    return NULL;
  }
  TileCacheEntry *existing = find_tile(world_x, world_y, zoom);
  if (existing) {
    if (diag) {
      diag->reason = "existing";
    }
    return existing;
  }

  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if (!s_tiles[i].valid && !s_tiles[i].pending) {
      if (diag) {
        diag->reason = "empty";
      }
      s_tiles[i].world_x = world_x;
      s_tiles[i].world_y = world_y;
      s_tiles[i].zoom = zoom;
      s_tiles[i].last_used = ++s_access_counter;
      return &s_tiles[i];
    }
  }

  int replace_index = -1;
  uint32_t oldest = UINT32_MAX;
  const char *replace_reason = "evictOffscreen";
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].pending) {
      continue;
    }
    if (!tile_is_visible(&s_tiles[i]) && s_tiles[i].last_used < oldest) {
      oldest = s_tiles[i].last_used;
      replace_index = i;
    }
  }

  if (replace_index < 0) {
    replace_reason = "evictLru";
    for (int i = 0; i < capacity; i++) {
      if (!s_tiles[i].pending && s_tiles[i].last_used < oldest) {
        oldest = s_tiles[i].last_used;
        replace_index = i;
      }
    }
  }

  if (replace_index < 0) {
    if (diag) {
      diag->reason = "deferAllPending";
    }
    return NULL;
  }

  TileCacheEntry *entry = &s_tiles[replace_index];
  if (diag) {
    diag->reason = replace_reason;
    diag->evicted = entry->valid || entry->pending;
    diag->old_valid = entry->valid;
    diag->old_pending = entry->pending;
    diag->old_world_x = entry->world_x;
    diag->old_world_y = entry->world_y;
    diag->old_zoom = entry->zoom;
  }
  entry->world_x = world_x;
  entry->world_y = world_y;
  entry->zoom = zoom;
  entry->valid = false;
  clear_tile_pending(entry);
  entry->animation_active = false;
  entry->animation_mode = TILE_ANIMATION_NONE;
  entry->last_used = ++s_access_counter;
  return entry;
}

int valid_visible_tile_count(void) {
  if (!s_tiles) {
    return 0;
  }
  int count = 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].valid && tile_is_visible(&s_tiles[i])) {
      count++;
    }
  }
  return count;
}

bool visible_grid_has_missing_tiles(void) {
  if (!s_has_gps || s_screen_bounds.size.w == 0 || s_screen_bounds.size.h == 0) {
    return false;
  }

  TileRequest origins[TILE_CACHE_SIZE];
  int count = visible_tile_origins(origins, active_tile_cache_size());
  for (int i = 0; i < count; i++) {
    TileCacheEntry *entry = find_tile(origins[i].world_x, origins[i].world_y,
                                      origins[i].zoom);
    if (!entry || (!entry->valid && !entry->pending)) {
      return true;
    }
  }
  return false;
}
