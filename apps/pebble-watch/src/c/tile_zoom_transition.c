#include "mappy.h"

// Compatible prior-zoom imagery retained while the committed grid reloads.

typedef struct {
  bool active;
  int8_t source_zoom;
  int8_t target_zoom;
  uint64_t retained_slots;
} ZoomFallbackState;

static ZoomFallbackState s_zoom_fallback;

typedef struct {
  int32_t left;
  int32_t top;
  int32_t right;
  int32_t bottom;
} TileWorldRect;

static int tile_slot_index(const TileCacheEntry *entry) {
  if (!entry || !s_tiles || entry < s_tiles || entry >= s_tiles + TILE_CACHE_SIZE) {
    return -1;
  }
  return (int)(entry - s_tiles);
}

static uint64_t tile_slot_bit(const TileCacheEntry *entry) {
  int index = tile_slot_index(entry);
  return index >= 0 ? ((uint64_t)1 << index) : 0;
}

static TileWorldRect current_viewport_world_bounds(void) {
  TileWorldRect bounds = {
    .left = s_viewport_x - (s_screen_bounds.size.w / 2),
    .top = s_viewport_y - (s_screen_bounds.size.h / 2),
    .right = s_viewport_x + ((s_screen_bounds.size.w + 1) / 2),
    .bottom = s_viewport_y + ((s_screen_bounds.size.h + 1) / 2),
  };
  if (!map_orientation_active()) {
    return bounds;
  }

  const int32_t half_w = s_screen_bounds.size.w / 2;
  const int32_t half_h = s_screen_bounds.size.h / 2;
  const int32_t corners[4][2] = {
    {-half_w, -half_h}, {half_w, -half_h},
    {half_w, half_h}, {-half_w, half_h},
  };
  bounds.left = INT32_MAX;
  bounds.top = INT32_MAX;
  bounds.right = INT32_MIN;
  bounds.bottom = INT32_MIN;
  for (int i = 0; i < 4; i++) {
    int32_t world_dx;
    int32_t world_dy;
    screen_delta_to_world_delta(corners[i][0], corners[i][1],
                                &world_dx, &world_dy);
    int32_t world_x = s_viewport_x + world_dx;
    int32_t world_y = s_viewport_y + world_dy;
    if (world_x < bounds.left) {
      bounds.left = world_x;
    }
    if (world_x > bounds.right) {
      bounds.right = world_x;
    }
    if (world_y < bounds.top) {
      bounds.top = world_y;
    }
    if (world_y > bounds.bottom) {
      bounds.bottom = world_y;
    }
  }
  bounds.right++;
  bounds.bottom++;
  return bounds;
}

static TileWorldRect entry_rect_at_target_zoom(const TileCacheEntry *entry) {
  TileWorldRect rect = {0};
  if (!entry) {
    return rect;
  }
  rect.left = scale_world_to_zoom(entry->world_x, entry->zoom,
                                  s_viewport_zoom);
  rect.top = scale_world_to_zoom(entry->world_y, entry->zoom,
                                 s_viewport_zoom);
  // The right and bottom edges are exclusive.  When projecting to a lower
  // zoom they therefore need ceil division; floor projection can otherwise
  // drop the final destination row/column at a source-tile boundary.
  rect.right = scale_world_extent_end_to_zoom(
      entry->world_x + s_tile_width, entry->zoom, s_viewport_zoom);
  rect.bottom = scale_world_extent_end_to_zoom(
      entry->world_y + s_tile_height, entry->zoom, s_viewport_zoom);
  if (rect.right <= rect.left) {
    rect.right = rect.left + 1;
  }
  if (rect.bottom <= rect.top) {
    rect.bottom = rect.top + 1;
  }
  return rect;
}

static bool rect_intersects(TileWorldRect a, TileWorldRect b) {
  return a.left < b.right && a.right > b.left &&
      a.top < b.bottom && a.bottom > b.top;
}

static bool clamp_rect(TileWorldRect *rect, TileWorldRect bounds) {
  if (!rect || !rect_intersects(*rect, bounds)) {
    return false;
  }
  if (rect->left < bounds.left) {
    rect->left = bounds.left;
  }
  if (rect->top < bounds.top) {
    rect->top = bounds.top;
  }
  if (rect->right > bounds.right) {
    rect->right = bounds.right;
  }
  if (rect->bottom > bounds.bottom) {
    rect->bottom = bounds.bottom;
  }
  return rect->left < rect->right && rect->top < rect->bottom;
}

bool zoom_fallback_active(void) {
  return s_zoom_fallback.active && s_zoom_fallback.retained_slots != 0;
}

int8_t zoom_fallback_source_zoom(void) {
  return s_zoom_fallback.source_zoom;
}

bool zoom_fallback_retains_entry(const TileCacheEntry *entry) {
  uint64_t bit = tile_slot_bit(entry);
  return bit != 0 && zoom_fallback_active() &&
      (s_zoom_fallback.retained_slots & bit) != 0 && entry->valid &&
      entry->zoom == s_zoom_fallback.source_zoom;
}

void zoom_fallback_release_entry(TileCacheEntry *entry) {
  uint64_t bit = tile_slot_bit(entry);
  if (bit != 0) {
    s_zoom_fallback.retained_slots &= ~bit;
  }
  if (s_zoom_fallback.retained_slots == 0) {
    s_zoom_fallback.active = false;
  }
}

void clear_zoom_fallback(void) {
  memset(&s_zoom_fallback, 0, sizeof(s_zoom_fallback));
}

static void discard_intermediate_zoom_entries(int8_t intermediate_zoom) {
  if (!s_tiles || intermediate_zoom == s_zoom_fallback.source_zoom) {
    return;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (!entry->valid || entry->zoom != intermediate_zoom ||
        zoom_fallback_retains_entry(entry)) {
      continue;
    }
    release_tile_storage(entry);
    entry->valid = false;
    entry->storage_suppressed = false;
    entry->animation_active = false;
    entry->animation_mode = TILE_ANIMATION_NONE;
  }
}

void begin_zoom_fallback(int8_t previous_zoom) {
  if (!s_tiles || s_screen_bounds.size.w <= 0 || s_screen_bounds.size.h <= 0) {
    clear_zoom_fallback();
    return;
  }

  if (zoom_fallback_active()) {
    int8_t previous_target = s_zoom_fallback.target_zoom;
    discard_intermediate_zoom_entries(previous_target);
    if (s_viewport_zoom == s_zoom_fallback.source_zoom) {
      clear_zoom_fallback();
      return;
    }
    s_zoom_fallback.target_zoom = s_viewport_zoom;
  } else {
    clear_zoom_fallback();
    s_zoom_fallback.active = true;
    s_zoom_fallback.source_zoom = previous_zoom;
    s_zoom_fallback.target_zoom = s_viewport_zoom;
  }

  TileWorldRect viewport = current_viewport_world_bounds();
  uint64_t retained = 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (entry->valid && entry->zoom == s_zoom_fallback.source_zoom &&
        rect_intersects(entry_rect_at_target_zoom(entry), viewport)) {
      retained |= (uint64_t)1 << i;
      complete_tile_animation(entry);
    }
  }
  s_zoom_fallback.retained_slots = retained;
  if (retained == 0) {
    s_zoom_fallback.active = false;
  }
}

bool zoom_fallback_entry_fully_covered(const TileCacheEntry *entry) {
  if (!zoom_fallback_retains_entry(entry)) {
    return false;
  }
  TileWorldRect rect = entry_rect_at_target_zoom(entry);
  if (!clamp_rect(&rect, current_viewport_world_bounds())) {
    return true;
  }

  int32_t start_x = floor_div_i32(rect.left, s_tile_width) * s_tile_width;
  int32_t start_y = floor_div_i32(rect.top, s_tile_height) * s_tile_height;
  for (int32_t y = start_y; y < rect.bottom; y += s_tile_height) {
    for (int32_t x = start_x; x < rect.right; x += s_tile_width) {
      TileCacheEntry *current = find_tile(x, y, s_viewport_zoom);
      if (!current || !current->valid) {
        return false;
      }
    }
  }
  return true;
}

bool zoom_fallback_entry_covered_by_tile(const TileCacheEntry *entry,
                                         int32_t world_x, int32_t world_y,
                                         int8_t zoom) {
  if (!zoom_fallback_retains_entry(entry) || zoom != s_viewport_zoom) {
    return false;
  }
  TileWorldRect rect = entry_rect_at_target_zoom(entry);
  if (!clamp_rect(&rect, current_viewport_world_bounds())) {
    return true;
  }
  TileWorldRect incoming = {
    .left = world_x,
    .top = world_y,
    .right = world_x + s_tile_width,
    .bottom = world_y + s_tile_height,
  };
  return incoming.left <= rect.left && incoming.top <= rect.top &&
      incoming.right >= rect.right && incoming.bottom >= rect.bottom;
}

void zoom_fallback_maybe_finish(void) {
  if (!zoom_fallback_active()) {
    return;
  }
  if (visible_grid_is_complete()) {
    clear_zoom_fallback();
    return;
  }
  TileWorldRect viewport = current_viewport_world_bounds();
  uint64_t remaining = 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    uint64_t bit = (uint64_t)1 << i;
    if ((s_zoom_fallback.retained_slots & bit) != 0 && entry->valid &&
        entry->zoom == s_zoom_fallback.source_zoom &&
        rect_intersects(entry_rect_at_target_zoom(entry), viewport)) {
      remaining |= bit;
    }
  }
  s_zoom_fallback.retained_slots = remaining;
  if (remaining == 0) {
    s_zoom_fallback.active = false;
  }
}
