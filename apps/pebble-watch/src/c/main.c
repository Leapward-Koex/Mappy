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
  stop_motion_detection_service();
  update_touch_subscription();
  cancel_menu_highlight_animation();
  complete_tile_animations();
  complete_gps_smoothing();
  cancel_map_bearing_smoothing();
  cancel_visual_animation_timer();
  cancel_tile_redraw();
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
  app_message_register_inbox_received(inbox_received);
  app_message_register_inbox_dropped(inbox_dropped);
  app_message_register_outbox_sent(outbox_sent);
  app_message_register_outbox_failed(outbox_failed);
  AppMessageResult app_message_result = app_message_open(4096, 512);
  if (app_message_result != APP_MSG_OK) {
    APP_LOG(APP_LOG_LEVEL_ERROR, "AppMessage open failed: %d", (int)app_message_result);
  }

  // AppMessage owns fixed inbox/outbox buffers for the lifetime of the app.
  // Reserve them before the opportunistic tile cache so navigation can always
  // cold-start. Tile images live in a fixed compressed arena rather than
  // consuming the remaining heap.
  s_tile_storage_bytes = malloc(TILE_STORAGE_ARENA_BYTES);
  s_tile_decode_scratch = malloc(MAX_TILE_BYTES);
  tile_storage_arena_init(&s_tile_storage_arena, s_tile_storage_bytes,
                          s_tile_storage_bytes ? TILE_STORAGE_ARENA_BYTES : 0);
  s_tiles = calloc(TILE_CACHE_SIZE, sizeof(TileCacheEntry));
  if (!s_tile_storage_bytes || !s_tile_decode_scratch || !s_tiles) {
    APP_LOG(APP_LOG_LEVEL_ERROR,
            "Tile cache allocation failed arena=%d scratch=%d entries=%d",
            s_tile_storage_bytes ? 1 : 0, s_tile_decode_scratch ? 1 : 0,
            s_tiles ? 1 : 0);
  } else {
    for (int i = 0; i < TILE_CACHE_SIZE; i++) {
      tile_storage_ref_reset(&s_tiles[i].storage);
    }
    if (!configure_tile_geometry(DEFAULT_TILE_W, DEFAULT_TILE_H)) {
      APP_LOG(APP_LOG_LEVEL_ERROR, "Tile storage configuration failed");
    }
  }

  s_window = window_create();
  window_set_background_color(s_window, GColorBlack);
  window_set_click_config_provider(s_window, click_config_provider);
  window_set_window_handlers(s_window, (WindowHandlers) {
    .load = window_load,
    .unload = window_unload,
  });
  window_stack_push(s_window, true);
  start_compass_service();
  APP_LOG(APP_LOG_LEVEL_INFO,
          "Mappy memory heap=%u arena=%u scratch=%u entries=%u",
          (unsigned)heap_bytes_free(), (unsigned)TILE_STORAGE_ARENA_BYTES,
          (unsigned)MAX_TILE_BYTES,
          (unsigned)(TILE_CACHE_SIZE * sizeof(TileCacheEntry)));

  s_state = AppStateWaitingForPhone;
  set_bottom_text(MAPPY_WAITING_TEXT);
  APP_LOG(APP_LOG_LEVEL_INFO, "Mappy watch waiting mode=%s", MAPPY_PHONE_MODE_LABEL);
  if (app_message_result == APP_MSG_OK) {
    send_init();
  } else {
    s_state = AppStateSetupRequired;
    copy_bounded_text(s_top_text, sizeof(s_top_text), "Connection error");
    set_bottom_text("Restart Mappy");
  }
}

void deinit(void) {
  cancel_init_retry();
  cancel_route_action_retry();
  s_menu_mode = MenuNone;
  stop_motion_detection_service();
  stop_compass_service();
  update_touch_subscription();
  cancel_menu_highlight_animation();
  complete_tile_animations();
  complete_gps_smoothing();
  cancel_map_bearing_smoothing();
  cancel_visual_animation_timer();
  cancel_tile_redraw();
  cancel_all_tile_requests();
  if (s_tile_request_resume_timer) {
    app_timer_cancel(s_tile_request_resume_timer);
    s_tile_request_resume_timer = NULL;
  }
  if (s_window) {
    window_destroy(s_window);
  }
  if (s_tiles) {
    free(s_tiles);
    s_tiles = NULL;
  }
  tile_storage_arena_reset(&s_tile_storage_arena);
  if (s_tile_storage_bytes) {
    free(s_tile_storage_bytes);
    s_tile_storage_bytes = NULL;
  }
  if (s_tile_decode_scratch) {
    free(s_tile_decode_scratch);
    s_tile_decode_scratch = NULL;
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
