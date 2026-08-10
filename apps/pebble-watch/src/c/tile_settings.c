#include "mappy.h"

// Tile-affecting settings handlers from the phone protocol.

void apply_theme(DictionaryIterator *iter) {
  Tuple *mode_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  int next_theme = mode_tuple ? mode_tuple->value->int32 : 0;
  if (next_theme < 0 || next_theme > 2) {
    next_theme = 0;
  }
  if (next_theme != s_theme_mode) {
    s_theme_mode = next_theme;
    persist_write_int(PERSIST_THEME, s_theme_mode);
    invalidate_tiles_with_reason(TileInvalidateTheme);
    queue_visible_tiles();
    if (s_map_layer) {
      layer_mark_dirty(s_map_layer);
    }
  }
}

void apply_map_settings(DictionaryIterator *iter) {
  Tuple *width_tuple = dict_find(iter, MESSAGE_KEY_width);
  Tuple *height_tuple = dict_find(iter, MESSAGE_KEY_height);
  if (width_tuple || height_tuple) {
    int next_width = width_tuple ? width_tuple->value->int32 : s_tile_width;
    int next_height = height_tuple ? height_tuple->value->int32 : s_tile_height;
    APP_LOG(APP_LOG_LEVEL_INFO, "Map settings geometry %dx%d active=%dx%d cache=%d",
            next_width, next_height, s_tile_width, s_tile_height,
            active_tile_cache_size());
    if (next_width != s_tile_width || next_height != s_tile_height) {
      if (!configure_tile_geometry(next_width, next_height)) {
        set_bottom_text("Tile size rejected");
        send_log_event(3, next_width, next_height, "tile size rejected");
        return;
      }
    }
  }
  invalidate_tiles_with_reason(TileInvalidateMapSettings);
  queue_visible_tiles();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void apply_map_orientation(DictionaryIterator *iter) {
  Tuple *orientation_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  int next_orientation = orientation_tuple ? orientation_tuple->value->int32 : s_map_orientation;
  if (next_orientation != 0 && next_orientation != 1) {
    next_orientation = 0;
  }
  if (next_orientation != s_map_orientation) {
    complete_gps_smoothing();
    bool was_orientation_active = map_orientation_active();
    s_map_orientation = next_orientation;
    persist_write_int(PERSIST_MAP_ORIENTATION, s_map_orientation);
    if (!was_orientation_active && map_orientation_active()) {
      s_map_bearing_display_centi_degrees = 0;
    }
    sync_map_bearing_smoothing(true);
    if (was_orientation_active || map_orientation_active()) {
      complete_tile_animations();
    }
    update_state_after_map_change();
    if (was_orientation_active || map_orientation_active()) {
      queue_visible_tiles();
    }
    refresh_motion_detection_service();
    if (s_map_layer) {
      layer_mark_dirty(s_map_layer);
    }
  }
}

void apply_tile_animation(DictionaryIterator *iter) {
  Tuple *mode_tuple = dict_find(iter, MESSAGE_KEY_button_id);
  int next_mode = normalize_tile_animation_mode(mode_tuple ?
      mode_tuple->value->int32 : TILE_ANIMATION_NONE);
  if (next_mode != s_tile_animation_mode) {
    s_tile_animation_mode = next_mode;
    persist_write_int(PERSIST_TILE_ANIMATION, s_tile_animation_mode);
    if (s_tile_animation_mode == TILE_ANIMATION_NONE) {
      complete_tile_animations();
    }
    if (s_map_layer) {
      layer_mark_dirty(s_map_layer);
    }
  }
}
