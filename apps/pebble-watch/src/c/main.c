#include "mappy.h"

// Pebble app lifecycle and window setup.

void window_load(Window *window) {
  Layer *root = window_get_root_layer(window);
  s_screen_bounds = layer_get_bounds(root);
  s_map_layer = layer_create(s_screen_bounds);
  layer_set_update_proc(s_map_layer, map_layer_update);
  layer_add_child(root, s_map_layer);
  update_touch_subscription();
}

void window_unload(Window *window) {
  s_menu_mode = MenuNone;
  update_touch_subscription();
  cancel_menu_highlight_animation();
  complete_tile_animations();
  complete_gps_smoothing();
  cancel_map_bearing_smoothing();
  cancel_visual_animation_timer();
  layer_destroy(s_map_layer);
  s_map_layer = NULL;
}

void load_settings(void) {
  s_theme_mode = persist_exists(PERSIST_THEME) ? persist_read_int(PERSIST_THEME) : 0;
  if (s_theme_mode < 0 || s_theme_mode > 2) {
    s_theme_mode = 0;
  }
  s_travel_mode = persist_exists(PERSIST_TRAVEL_MODE) ? persist_read_int(PERSIST_TRAVEL_MODE) : 2;
  if (s_travel_mode < 0 || s_travel_mode > 2) {
    s_travel_mode = 2;
  }
  s_backlight_mode = persist_exists(PERSIST_BACKLIGHT) ? persist_read_int(PERSIST_BACKLIGHT) : 0;
  if (s_backlight_mode != 0 && s_backlight_mode != 1) {
    s_backlight_mode = 0;
  }
  light_enable(s_backlight_mode == 1);
  s_units_mode = persist_exists(PERSIST_UNITS) ? persist_read_int(PERSIST_UNITS) : 1;
  if (s_units_mode != 0 && s_units_mode != 1) {
    s_units_mode = 1;
  }
  s_map_orientation = persist_exists(PERSIST_MAP_ORIENTATION) ?
      persist_read_int(PERSIST_MAP_ORIENTATION) : 0;
  if (s_map_orientation != 0 && s_map_orientation != 1) {
    s_map_orientation = 0;
  }
  s_tile_animation_mode = normalize_tile_animation_mode(
      persist_exists(PERSIST_TILE_ANIMATION) ?
          persist_read_int(PERSIST_TILE_ANIMATION) : TILE_ANIMATION_FADE);
  s_viewport_zoom = persist_exists(PERSIST_ZOOM) ? persist_read_int(PERSIST_ZOOM) : ROUTE_WORLD_ZOOM;
  if (s_viewport_zoom < MIN_MAP_ZOOM || s_viewport_zoom > MAX_MAP_ZOOM) {
    s_viewport_zoom = ROUTE_WORLD_ZOOM;
  }
  s_transient_zoom_scale_q8 = TRANSIENT_SCALE_Q8_ONE;
}

void init(void) {
  APP_LOG(APP_LOG_LEVEL_INFO, "Mappy watch init mode=%s", MAPPY_PHONE_MODE_LABEL);
  load_settings();
  s_tiles = calloc(TILE_CACHE_SIZE, sizeof(TileCacheEntry));
  if (!s_tiles) {
    APP_LOG(APP_LOG_LEVEL_ERROR, "Tile cache allocation failed");
  } else if (!configure_tile_geometry(DEFAULT_TILE_W, DEFAULT_TILE_H)) {
    APP_LOG(APP_LOG_LEVEL_ERROR, "Tile decode buffer allocation failed");
  }
  app_message_register_inbox_received(inbox_received);
  app_message_register_inbox_dropped(inbox_dropped);
  app_message_register_outbox_sent(outbox_sent);
  app_message_register_outbox_failed(outbox_failed);
  app_message_open(4096, 512);

  s_window = window_create();
  window_set_background_color(s_window, GColorBlack);
  window_set_click_config_provider(s_window, click_config_provider);
  window_set_window_handlers(s_window, (WindowHandlers) {
    .load = window_load,
    .unload = window_unload,
  });
  window_stack_push(s_window, true);
  start_compass_service();

  s_state = AppStateWaitingForPhone;
  set_bottom_text(MAPPY_WAITING_TEXT);
  APP_LOG(APP_LOG_LEVEL_INFO, "Mappy watch waiting mode=%s", MAPPY_PHONE_MODE_LABEL);
  send_init();
}

void deinit(void) {
  s_menu_mode = MenuNone;
  stop_compass_service();
  update_touch_subscription();
  cancel_menu_highlight_animation();
  complete_tile_animations();
  complete_gps_smoothing();
  cancel_map_bearing_smoothing();
  cancel_visual_animation_timer();
  reset_tile_chunk_assembly();
  if (s_window) {
    window_destroy(s_window);
  }
  if (s_tiles) {
    free(s_tiles);
    s_tiles = NULL;
  }
  if (s_tile_decode_buffer) {
    free(s_tile_decode_buffer);
    s_tile_decode_buffer = NULL;
  }
  if (s_destinations) {
    free(s_destinations);
    s_destinations = NULL;
    s_destination_count = 0;
  }
}

int main(void) {
  init();
  app_event_loop();
  deinit();
}
