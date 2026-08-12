#include "mappy.h"

// Tile load animation timing and scheduling.

uint16_t tile_animation_duration_ms(uint8_t mode) {
  return mode == TILE_ANIMATION_FADE_ZOOM ?
      TILE_ANIMATION_FADE_ZOOM_MS : TILE_ANIMATION_FADE_MS;
}

uint16_t tile_animation_elapsed_ms(const TileCacheEntry *entry) {
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  int32_t elapsed = (int32_t)(now_s - entry->animation_started_s) * 1000 +
      (int32_t)now_ms - (int32_t)entry->animation_started_ms;
  if (elapsed < 0) {
    return 0;
  }
  if (elapsed > UINT16_MAX) {
    return UINT16_MAX;
  }
  return (uint16_t)elapsed;
}

uint16_t tile_animation_progress_q8(const TileCacheEntry *entry) {
  if (!entry->animation_active) {
    return 256;
  }
  uint16_t duration = tile_animation_duration_ms(entry->animation_mode);
  uint16_t elapsed = tile_animation_elapsed_ms(entry);
  if (elapsed >= duration) {
    return 256;
  }
  return (uint16_t)(((uint32_t)elapsed * 256) / duration);
}

uint16_t tile_animation_eased_q8(uint16_t progress_q8) {
  if (progress_q8 >= 256) {
    return 256;
  }
  uint32_t remaining = 256 - progress_q8;
  uint32_t eased_remaining = (remaining * remaining * remaining) / (256UL * 256UL);
  return (uint16_t)(256 - eased_remaining);
}

void complete_tile_animation(TileCacheEntry *entry) {
  entry->animation_active = false;
  entry->animation_mode = TILE_ANIMATION_NONE;
}

bool any_tile_animation_active(void) {
  if (!s_tiles) {
    return false;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].animation_active) {
      return true;
    }
  }
  return false;
}

void complete_tile_animations(void) {
  if (!s_tiles) {
    release_visual_animation_tick_if_idle();
    return;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    complete_tile_animation(&s_tiles[i]);
  }
  release_visual_animation_tick_if_idle();
}

bool advance_tile_animations(void) {
  bool visible_changed = false;
  if (!s_tiles) {
    return false;
  }
  bool use_origin_snapshot = map_orientation_active();
  TileRequest origins[TILE_CACHE_SIZE];
  int origin_count = use_origin_snapshot ?
      visible_tile_origins(origins, active_tile_cache_size()) : 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (!entry->animation_active) {
      continue;
    }
    bool visible = entry->valid && entry->zoom == s_viewport_zoom &&
        (use_origin_snapshot ? tile_origin_list_contains(
            origins, origin_count, entry->world_x, entry->world_y,
            entry->zoom) : tile_is_visible(entry));
    if (visible) {
      visible_changed = true;
    }
    if (!visible) {
      complete_tile_animation(entry);
    } else if (tile_animation_progress_q8(entry) >= 256) {
      // Give the render pass one event-loop turn to draw and commit the final
      // frame. NONE while active is the zero-allocation completion sentinel;
      // the next scheduler tick cleans up entries outside the render set.
      if (entry->animation_mode == TILE_ANIMATION_NONE) {
        complete_tile_animation(entry);
      } else {
        entry->animation_mode = TILE_ANIMATION_NONE;
      }
    }
  }
  return visible_changed;
}

bool start_tile_animation(TileCacheEntry *entry, bool was_pending) {
  if (!entry) {
    return false;
  }
  entry->animation_active = false;
  entry->animation_mode = TILE_ANIMATION_NONE;
  int mode = normalize_tile_animation_mode(s_tile_animation_mode);
  if (!was_pending || mode == TILE_ANIMATION_NONE || !tile_is_visible(entry) ||
      !map_bearing_rendering_visible()) {
    return false;
  }
#ifdef PBL_TOUCH
  if (s_touch_active) {
    return false;
  }
#endif

  time_ms(&entry->animation_started_s, &entry->animation_started_ms);
  entry->animation_mode = (uint8_t)mode;
  entry->animation_active = true;
  schedule_visual_animation_tick();
  if (!s_visual_animation_timer) {
    complete_tile_animation(entry);
    return false;
  }
  return true;
}
