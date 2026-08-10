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

void finish_inactive_tile_animations(void) {
  if (!s_tiles) {
    return;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (!entry->animation_active) {
      continue;
    }
    if (!entry->valid || entry->zoom != s_viewport_zoom ||
        !tile_is_visible(entry) || tile_animation_progress_q8(entry) >= 256) {
      complete_tile_animation(entry);
    }
  }
}

bool any_tile_animation_active(void) {
  if (!s_tiles) {
    return false;
  }
  finish_inactive_tile_animations();
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].animation_active) {
      return true;
    }
  }
  return false;
}

void cancel_tile_animation_timer(void) {
  if (s_tile_animation_timer) {
    app_timer_cancel(s_tile_animation_timer);
    s_tile_animation_timer = NULL;
  }
}

void complete_tile_animations(void) {
  cancel_tile_animation_timer();
  if (!s_tiles) {
    return;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    complete_tile_animation(&s_tiles[i]);
  }
}

void finish_elapsed_tile_animations(void) {
  finish_inactive_tile_animations();
}

void tile_animation_timer_callback(void *data) {
  (void)data;
  s_tile_animation_timer = NULL;
  finish_elapsed_tile_animations();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  if (any_tile_animation_active()) {
    s_tile_animation_timer = app_timer_register(TILE_ANIMATION_TICK_MS,
                                                tile_animation_timer_callback, NULL);
  }
}

void schedule_tile_animation_tick(void) {
  if (!s_tile_animation_timer && any_tile_animation_active()) {
    s_tile_animation_timer = app_timer_register(TILE_ANIMATION_TICK_MS,
                                                tile_animation_timer_callback, NULL);
  }
}

void start_tile_animation(TileCacheEntry *entry, bool was_pending) {
  if (!entry) {
    return;
  }
  entry->animation_active = false;
  entry->animation_mode = TILE_ANIMATION_NONE;
  int mode = normalize_tile_animation_mode(s_tile_animation_mode);
  if (!was_pending || mode == TILE_ANIMATION_NONE || !tile_is_visible(entry) ||
      s_menu_mode != MenuNone) {
    return;
  }
#ifdef PBL_TOUCH
  if (touch_interaction_recent()) {
    return;
  }
#endif

  time_ms(&entry->animation_started_s, &entry->animation_started_ms);
  entry->animation_mode = (uint8_t)mode;
  entry->animation_active = true;
  schedule_tile_animation_tick();
}
