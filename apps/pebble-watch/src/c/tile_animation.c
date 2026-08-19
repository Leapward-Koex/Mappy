#include "mappy.h"

// Tile load animation timing and scheduling.

static int active_tile_animation_count(
    const TileCacheEntry **oldest_active) {
  if (oldest_active) {
    *oldest_active = NULL;
  }
  if (!s_tiles) {
    return 0;
  }

  int count = 0;
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    const TileCacheEntry *candidate = &s_tiles[i];
    if (!candidate->animation_active ||
        candidate->animation_mode == TILE_ANIMATION_NONE) {
      continue;
    }
    count++;
    if (oldest_active && !*oldest_active) {
      // Every tile that joins a burst inherits this timestamp, so the first
      // active entry is also the burst anchor.
      *oldest_active = candidate;
    }
    if (count >= TILE_ANIMATION_MAX_ACTIVE) {
      return count;
    }
  }
  return count;
}

uint16_t tile_animation_duration_ms(uint8_t mode) {
  return mode == TILE_ANIMATION_FADE_ZOOM ?
      TILE_ANIMATION_FADE_ZOOM_MS : TILE_ANIMATION_FADE_MS;
}

static uint16_t tile_animation_elapsed_at_ms(const TileCacheEntry *entry,
                                             time_t now_s,
                                             uint16_t now_ms) {
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

uint16_t tile_animation_elapsed_ms(const TileCacheEntry *entry) {
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  return tile_animation_elapsed_at_ms(entry, now_s, now_ms);
}

uint16_t tile_animation_progress_at_q8(const TileCacheEntry *entry,
                                       time_t now_s,
                                       uint16_t now_ms) {
  if (!entry->animation_active) {
    return 256;
  }
  uint16_t duration = tile_animation_duration_ms(entry->animation_mode);
  uint16_t elapsed = tile_animation_elapsed_at_ms(entry, now_s, now_ms);
  if (elapsed >= duration) {
    return 256;
  }
  return (uint16_t)(((uint32_t)elapsed * 256) / duration);
}

uint16_t tile_animation_progress_q8(const TileCacheEntry *entry) {
  if (!entry->animation_active) {
    return 256;
  }
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  return tile_animation_progress_at_q8(entry, now_s, now_ms);
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
  if (!any_tile_animation_active()) {
    return false;
  }
  bool use_origin_snapshot = map_orientation_active();
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
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
    } else if (tile_animation_progress_at_q8(entry, now_s, now_ms) >= 256) {
      // This callback already dirties the map below, so the final redraw uses
      // the exact static tile without keeping a sentinel timer alive.
      complete_tile_animation(entry);
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
  // Never let decorative tile work compete with direct manipulation or coast
  // settlement. Retained zoom fallback deliberately remains eligible so zoom
  // changes preserve their configured tile reveal; the bounded burst policy
  // below keeps that extra composite work short.
  if (pan_inertia_animation_active()) {
    return false;
  }

  const TileCacheEntry *oldest_active = NULL;
  int active_count = active_tile_animation_count(&oldest_active);
  if (active_count >= TILE_ANIMATION_MAX_ACTIVE) {
    return false;
  }
  // Avoid multiplying the expensive scale path when several tiles arrive in
  // one burst. The second tile still gets the cheaper reveal.
  if (mode == TILE_ANIMATION_FADE_ZOOM && active_count > 0) {
    mode = TILE_ANIMATION_FADE;
  }

  if (oldest_active) {
    // Cohort staggered arrivals onto one bounded burst instead of granting each
    // tile a fresh lifetime that can keep the map continuously dirty.
    entry->animation_started_s = oldest_active->animation_started_s;
    entry->animation_started_ms = oldest_active->animation_started_ms;
  } else {
    time_ms(&entry->animation_started_s, &entry->animation_started_ms);
  }
  entry->animation_mode = (uint8_t)mode;
  entry->animation_active = true;
  if (tile_animation_progress_q8(entry) >= 256) {
    complete_tile_animation(entry);
    return false;
  }
  schedule_visual_animation_tick();
  if (!s_visual_animation_timer) {
    complete_tile_animation(entry);
    return false;
  }
  return true;
}
