#include "mappy.h"

// Cache entries have two different kinds of value during a zoom transition:
// target-zoom tiles are the requested result, while retained source-zoom tiles
// are temporary fallback imagery.  Keep the pressure order explicit and
// shared by slot and byte-arena eviction so the temporary fallback can never
// displace an already-rendered target tile.
typedef enum {
  TileCachePressureIneligible = 0,
  TileCachePressureOffscreen = 1,
  TileCachePressureCoveredFallback = 2,
  TileCachePressureIncomingCoveredFallback = 3,
  TileCachePressureFallback = 4,
  TileCachePressureSuppressedVisible = 5,
  TileCachePressureLessImportantVisible = 6,
} TileCachePressurePriority;

typedef struct {
  TileCachePressurePriority priority;
  uint32_t distance_sq;
  uint32_t last_used;
} TileCachePressureCandidate;

static int tile_cache_select_pressure_candidate(
    const TileCachePressureCandidate *candidates, int count,
    uint32_t incoming_distance_sq) {
  if (!candidates || count <= 0) {
    return -1;
  }

  int selected = -1;
  for (int i = 0; i < count; i++) {
    const TileCachePressureCandidate *candidate = &candidates[i];
    if (candidate->priority == TileCachePressureIneligible) {
      continue;
    }
    // A newly arriving fringe tile must not punch a hole closer to the center
    // of the current grid.  Equal-importance entries also stay put to avoid
    // oscillating between equally distant tiles under sustained pressure.
    if (candidate->priority == TileCachePressureLessImportantVisible &&
        candidate->distance_sq <= incoming_distance_sq) {
      continue;
    }
    if (selected < 0) {
      selected = i;
      continue;
    }

    const TileCachePressureCandidate *best = &candidates[selected];
    if (candidate->priority < best->priority) {
      selected = i;
      continue;
    }
    if (candidate->priority > best->priority) {
      continue;
    }
    if (candidate->priority == TileCachePressureLessImportantVisible &&
        candidate->distance_sq != best->distance_sq) {
      if (candidate->distance_sq > best->distance_sq) {
        selected = i;
      }
      continue;
    }
    if (candidate->last_used < best->last_used) {
      selected = i;
    }
  }
  return selected;
}

#ifndef MAPPY_TILE_CACHE_POLICY_HOST_TEST

// Tile cache bookkeeping and visibility checks. Request lifetime is owned by
// TileFlight records in tile_requests.c, not by cache entries.

void invalidate_tiles_with_reason(TileInvalidationReason reason) {
  complete_tile_animations();
  clear_zoom_fallback();
  cancel_all_tile_requests();
  cancel_tile_redraw();
  invalidate_orientation_tile_coverage();
  if (!s_tiles) {
    s_request_count = 0;
    s_request_index = 0;
    APP_LOG(APP_LOG_LEVEL_INFO, "Tile invalidate reason=%s cache=0/%d",
            tile_invalidation_reason_label(reason), TILE_CACHE_SIZE);
    return;
  }
  int valid_count = 0;
  int pending_count = any_pending_tile_requests() ? 1 : 0;
  int capacity = active_tile_cache_size();
  tile_storage_arena_reset(&s_tile_storage_arena);
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].valid) {
      valid_count++;
    }
    s_tiles[i].valid = false;
    s_tiles[i].storage_suppressed = false;
    tile_storage_ref_reset(&s_tiles[i].storage);
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
    if ((s_tiles[i].valid || s_tiles[i].storage_suppressed) &&
        tile_matches(&s_tiles[i], world_x, world_y, zoom)) {
      return &s_tiles[i];
    }
  }
  return NULL;
}

static uint32_t tile_coordinate_distance_sq(int32_t world_x,
                                            int32_t world_y) {
  int64_t center_x = (int64_t)world_x + (s_tile_width / 2);
  int64_t center_y = (int64_t)world_y + (s_tile_height / 2);
  int64_t dx = center_x - s_viewport_x;
  int64_t dy = center_y - s_viewport_y;
  uint64_t abs_dx = (uint64_t)(dx < 0 ? -dx : dx);
  uint64_t abs_dy = (uint64_t)(dy < 0 ? -dy : dy);
  if (abs_dx > UINT16_MAX || abs_dy > UINT16_MAX) {
    return UINT32_MAX;
  }
  uint64_t distance_sq = abs_dx * abs_dx + abs_dy * abs_dy;
  return distance_sq > UINT32_MAX ? UINT32_MAX : (uint32_t)distance_sq;
}

static uint32_t tile_origin_distance_sq(const TileRequest *request) {
  return tile_coordinate_distance_sq(request->world_x, request->world_y);
}

static bool tile_origin_precedes(const TileRequest *a, const TileRequest *b) {
  uint32_t distance_a = tile_origin_distance_sq(a);
  uint32_t distance_b = tile_origin_distance_sq(b);
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

bool tile_origin_list_contains(const TileRequest *origins, int count,
                               int32_t world_x, int32_t world_y, int8_t zoom) {
  if (!origins || count <= 0) {
    return false;
  }
  for (int i = 0; i < count; i++) {
    if (origins[i].world_x == world_x && origins[i].world_y == world_y &&
        origins[i].zoom == zoom) {
      return true;
    }
  }
  return false;
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

static TileCachePressurePriority tile_cache_pressure_priority(
    TileCacheEntry *entry, int32_t incoming_world_x,
    int32_t incoming_world_y, int8_t incoming_zoom) {
  bool retained = zoom_fallback_retains_entry(entry);
  if (retained && zoom_fallback_entry_fully_covered(entry)) {
    return TileCachePressureCoveredFallback;
  }
  if (retained && zoom_fallback_entry_covered_by_tile(
                      entry, incoming_world_x, incoming_world_y,
                      incoming_zoom)) {
    return TileCachePressureIncomingCoveredFallback;
  }
  if (retained) {
    return TileCachePressureFallback;
  }
  if (!tile_is_visible(entry)) {
    return TileCachePressureOffscreen;
  }
  if (!entry->valid) {
    return TileCachePressureSuppressedVisible;
  }
  return TileCachePressureLessImportantVisible;
}

static const char *tile_cache_pressure_reason(
    TileCachePressurePriority priority) {
  switch (priority) {
    case TileCachePressureOffscreen:
      return "evictOffscreen";
    case TileCachePressureCoveredFallback:
      return "evictSupersededFallback";
    case TileCachePressureIncomingCoveredFallback:
      return "evictIncomingCoveredFallback";
    case TileCachePressureFallback:
      return "evictFallbackPressure";
    case TileCachePressureSuppressedVisible:
      return "evictSuppressedVisible";
    case TileCachePressureLessImportantVisible:
      return "evictLessImportantVisible";
    case TileCachePressureIneligible:
    default:
      return "deferVisiblePriority";
  }
}

TileCacheEntry *allocate_tile_slot_with_diagnostics(int32_t world_x, int32_t world_y,
                                                           int8_t zoom,
                                                           TileSlotDiagnostics *diag) {
  if (diag) {
    diag->reason = "unknown";
  }
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
    if (!s_tiles[i].valid && !s_tiles[i].storage_suppressed) {
      if (diag) {
        diag->reason = "empty";
      }
      s_tiles[i].world_x = world_x;
      s_tiles[i].world_y = world_y;
      s_tiles[i].zoom = zoom;
      release_tile_storage(&s_tiles[i]);
      s_tiles[i].storage_suppressed = false;
      s_tiles[i].last_used = ++s_access_counter;
      return &s_tiles[i];
    }
  }

  TileCachePressureCandidate candidates[TILE_CACHE_SIZE];
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *candidate = &s_tiles[i];
    candidates[i].priority = tile_cache_pressure_priority(
        candidate, world_x, world_y, zoom);
    candidates[i].distance_sq = tile_coordinate_distance_sq(
        candidate->world_x, candidate->world_y);
    candidates[i].last_used = candidate->last_used;
  }

  uint32_t incoming_distance_sq = tile_coordinate_distance_sq(world_x,
                                                              world_y);
  int replace_index = tile_cache_select_pressure_candidate(
      candidates, capacity, incoming_distance_sq);
  if (replace_index < 0) {
    if (diag) {
      diag->reason = "deferVisiblePriority";
    }
    return NULL;
  }

  TileCacheEntry *entry = &s_tiles[replace_index];
  if (diag) {
    diag->reason = tile_cache_pressure_reason(
        candidates[replace_index].priority);
  }
  entry->world_x = world_x;
  entry->world_y = world_y;
  entry->zoom = zoom;
  entry->valid = false;
  release_tile_storage(entry);
  entry->storage_suppressed = false;
  entry->animation_active = false;
  entry->animation_mode = TILE_ANIMATION_NONE;
  entry->last_used = ++s_access_counter;
  return entry;
}

void release_tile_storage(TileCacheEntry *entry) {
  zoom_fallback_release_entry(entry);
  if (!entry || !s_tiles || !tile_storage_ref_valid(&entry->storage)) {
    if (entry) {
      tile_storage_ref_reset(&entry->storage);
      entry->encoded_length = 0;
    }
    return;
  }
  tile_storage_arena_remove(&s_tile_storage_arena, &entry->storage,
                            &s_tiles[0].storage, active_tile_cache_size(),
                            sizeof(TileCacheEntry));
  entry->encoded_length = 0;
}

static TileCacheEntry *storage_eviction_candidate(TileCacheEntry *target) {
  TileCachePressureCandidate candidates[TILE_CACHE_SIZE];
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *candidate = &s_tiles[i];
    candidates[i].priority = TileCachePressureIneligible;
    if (candidate != target && candidate->valid &&
        tile_storage_ref_valid(&candidate->storage)) {
      candidates[i].priority = tile_cache_pressure_priority(
          candidate, target->world_x, target->world_y, target->zoom);
    }
    candidates[i].distance_sq = tile_coordinate_distance_sq(
        candidate->world_x, candidate->world_y);
    candidates[i].last_used = candidate->last_used;
  }

  uint32_t incoming_distance_sq = tile_coordinate_distance_sq(
      target->world_x, target->world_y);
  int index = tile_cache_select_pressure_candidate(
      candidates, capacity, incoming_distance_sq);
  if (index >= 0) {
    return &s_tiles[index];
  }
  return NULL;
}

bool reserve_tile_storage(TileCacheEntry *entry, uint16_t length,
                          TileStorageFormat format) {
  if (!entry || !s_tiles || length == 0 ||
      length > TILE_STORAGE_ARENA_BYTES) {
    return false;
  }

  release_tile_storage(entry);
  while ((uint32_t)s_tile_storage_arena.used + length >
         s_tile_storage_arena.capacity) {
    TileCacheEntry *evicted = storage_eviction_candidate(entry);
    if (!evicted) {
      return false;
    }
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Tile storage evict x=%ld y=%ld z=%d bytes=%u used=%u/%u",
            (long)evicted->world_x, (long)evicted->world_y,
            (int)evicted->zoom, (unsigned)evicted->storage.length,
            (unsigned)s_tile_storage_arena.used,
            (unsigned)s_tile_storage_arena.capacity);
    // Only suppress an unavoidable eviction from the current request grid.
    // A retained source-zoom tile is useful as fallback imagery, but it is not
    // request-visible at the target zoom.  Tombstoning it here would prevent a
    // rapid zoom reversal from ever requesting that coordinate again.
    bool evicted_was_request_visible = tile_is_visible(evicted);
    release_tile_storage(evicted);
    evicted->valid = false;
    evicted->storage_suppressed = evicted_was_request_visible;
    evicted->animation_active = false;
    evicted->animation_mode = TILE_ANIMATION_NONE;
  }
  return tile_storage_arena_reserve(&s_tile_storage_arena, &entry->storage,
                                    length, format);
}

int valid_visible_tile_count(void) {
  if (!s_tiles) {
    return 0;
  }
  bool use_origin_snapshot = map_orientation_active();
  TileRequest origins[TILE_CACHE_SIZE];
  int origin_count = use_origin_snapshot ?
      visible_tile_origins(origins, active_tile_cache_size()) : 0;
  int count = 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (!entry->valid) {
      continue;
    }
    bool visible = use_origin_snapshot ? tile_origin_list_contains(
        origins, origin_count, entry->world_x, entry->world_y, entry->zoom) :
        tile_is_visible(entry);
    if (visible) {
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
    if ((!entry || (!entry->valid && !entry->storage_suppressed)) &&
        !tile_request_is_suppressed(origins[i].world_x, origins[i].world_y,
                                    origins[i].zoom)) {
      return true;
    }
  }
  return false;
}

bool visible_grid_is_complete(void) {
  if (!s_has_gps || s_screen_bounds.size.w == 0 ||
      s_screen_bounds.size.h == 0) {
    return false;
  }

  TileRequest origins[TILE_CACHE_SIZE];
  int count = visible_tile_origins(origins, active_tile_cache_size());
  if (count <= 0) {
    return false;
  }
  for (int i = 0; i < count; i++) {
    TileCacheEntry *entry = find_tile(origins[i].world_x, origins[i].world_y,
                                      origins[i].zoom);
    if (!entry || !entry->valid) {
      return false;
    }
  }
  return true;
}

#endif  // MAPPY_TILE_CACHE_POLICY_HOST_TEST
