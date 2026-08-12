#include "mappy.h"

// Tile dimensions, decode-buffer allocation, and slot diagnostics.

int normalize_tile_animation_mode(int mode) {
  return (mode >= TILE_ANIMATION_NONE && mode <= TILE_ANIMATION_FADE_ZOOM) ?
      mode : TILE_ANIMATION_NONE;
}

const char *tile_invalidation_reason_label(TileInvalidationReason reason) {
  switch (reason) {
    case TileInvalidateTheme:
      return "theme";
    case TileInvalidateMapSettings:
      return "settings";
    case TileInvalidateZoom:
      return "zoom";
    case TileInvalidateUnknown:
    default:
      return "unknown";
  }
}

int ceil_div_i32(int value, int divisor) {
  return divisor > 0 ? (value + divisor - 1) / divisor : 0;
}

bool is_supported_tile_geometry(int width, int height) {
  return (width == 54 && height == 63) ||
      (width == 72 && height == 84) ||
      (width == 108 && height == 126);
}

int active_tile_cache_size(void) {
  if (s_tile_cache_size < 1) {
    return 0;
  }
  return s_tile_cache_size > TILE_CACHE_SIZE ? TILE_CACHE_SIZE : s_tile_cache_size;
}

void reset_tile_chunk_assembly(void) {
  s_tile_chunk_active = false;
  s_tile_chunk_store_packed = false;
  memset(&s_tile_chunk_decoder, 0, sizeof(s_tile_chunk_decoder));
  s_tile_chunk_world_x = 0;
  s_tile_chunk_world_y = 0;
  s_tile_chunk_zoom = 0;
  s_tile_chunk_width = 0;
  s_tile_chunk_height = 0;
  s_tile_chunk_total = 0;
  s_tile_chunk_received = 0;
  s_tile_chunk_next_index = 0;
  s_tile_chunk_request_id = 0;
}

bool configure_tile_geometry(int width, int height) {
  if (!is_supported_tile_geometry(width, height)) {
    return false;
  }

  int next_pixels = width * height;
  int next_bytes = (next_pixels + 1) / 2;
  if (next_pixels <= 0 || next_pixels > MAX_TILE_PIXELS || next_bytes > MAX_TILE_BYTES) {
    return false;
  }

  cancel_all_tile_requests();
  clear_zoom_fallback();
  tile_storage_arena_reset(&s_tile_storage_arena);
  if (s_tiles) {
    for (int i = 0; i < TILE_CACHE_SIZE; i++) {
      tile_storage_ref_reset(&s_tiles[i].storage);
      s_tiles[i].valid = false;
      s_tiles[i].storage_suppressed = false;
      s_tiles[i].animation_active = false;
      s_tiles[i].animation_mode = TILE_ANIMATION_NONE;
    }
  }
  s_tile_width = width;
  s_tile_height = height;
  s_tile_pixels = next_pixels;
  s_tile_bytes = next_bytes;
  s_tile_cache_size = TILE_CACHE_SIZE;
  APP_LOG(APP_LOG_LEVEL_INFO,
          "Tile geometry %dx%d packed=%d arena=%u cache=%d/%d",
          s_tile_width, s_tile_height, s_tile_bytes,
          (unsigned)TILE_STORAGE_ARENA_BYTES, active_tile_cache_size(),
          TILE_CACHE_SIZE);
  return true;
}
