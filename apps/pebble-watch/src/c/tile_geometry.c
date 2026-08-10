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

void init_tile_slot_diagnostics(TileSlotDiagnostics *diag) {
  if (!diag) {
    return;
  }
  diag->reason = "unknown";
  diag->evicted = false;
  diag->old_valid = false;
  diag->old_pending = false;
  diag->old_world_x = 0;
  diag->old_world_y = 0;
  diag->old_zoom = 0;
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

int tile_cache_size_for_bytes(int tile_bytes) {
  if (tile_bytes <= 0) {
    return MIN_TILE_CACHE_SIZE;
  }
  int capacity = TILE_DECODE_CACHE_BUDGET_BYTES / tile_bytes;
  if (capacity < MIN_TILE_CACHE_SIZE) {
    capacity = MIN_TILE_CACHE_SIZE;
  }
  if (capacity > TILE_CACHE_SIZE) {
    capacity = TILE_CACHE_SIZE;
  }
  return capacity;
}

void reset_tile_chunk_assembly(void) {
  s_tile_chunk_active = false;
  if (s_tile_chunk_buffer) {
    free(s_tile_chunk_buffer);
    s_tile_chunk_buffer = NULL;
  }
  s_tile_chunk_buffer_size = 0;
  s_tile_chunk_world_x = 0;
  s_tile_chunk_world_y = 0;
  s_tile_chunk_zoom = 0;
  s_tile_chunk_width = 0;
  s_tile_chunk_height = 0;
  s_tile_chunk_total = 0;
  s_tile_chunk_received = 0;
  s_tile_chunk_next_index = 0;
}

bool ensure_tile_chunk_buffer(int32_t required_bytes) {
  if (required_bytes <= 0 || required_bytes > MAX_RLE_BYTES) {
    return false;
  }
  if (s_tile_chunk_buffer && s_tile_chunk_buffer_size >= required_bytes) {
    return true;
  }

  if (s_tile_chunk_buffer) {
    free(s_tile_chunk_buffer);
    s_tile_chunk_buffer = NULL;
    s_tile_chunk_buffer_size = 0;
  }
  s_tile_chunk_buffer = malloc(required_bytes);
  if (!s_tile_chunk_buffer) {
    return false;
  }
  s_tile_chunk_buffer_size = required_bytes;
  return true;
}

void assign_tile_decode_buffers(void) {
  if (!s_tiles) {
    return;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < TILE_CACHE_SIZE; i++) {
    if (s_tile_decode_buffer && i < capacity) {
      s_tiles[i].decoded = s_tile_decode_buffer + (i * s_tile_bytes);
    } else {
      s_tiles[i].decoded = NULL;
      s_tiles[i].valid = false;
      clear_tile_pending(&s_tiles[i]);
      s_tiles[i].animation_active = false;
      s_tiles[i].animation_mode = TILE_ANIMATION_NONE;
    }
  }
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

  uint8_t *buffer = NULL;
  int next_capacity = tile_cache_size_for_bytes(next_bytes);
  if (s_tiles) {
    if (s_tile_decode_buffer) {
      free(s_tile_decode_buffer);
      s_tile_decode_buffer = NULL;
    }
    s_tile_cache_size = 0;
    assign_tile_decode_buffers();

    while (next_capacity >= MIN_TILE_CACHE_SIZE) {
      buffer = calloc(next_capacity, next_bytes);
      if (buffer) {
        break;
      }
      next_capacity--;
    }
    if (!buffer || next_capacity < MIN_TILE_CACHE_SIZE) {
      APP_LOG(APP_LOG_LEVEL_ERROR,
              "Tile decode buffer allocation failed for %dx%d bytes=%d cap<=%d",
              width, height, next_bytes, next_capacity + 1);
      return false;
    }
  }

  s_tile_width = width;
  s_tile_height = height;
  s_tile_pixels = next_pixels;
  s_tile_bytes = next_bytes;
  s_tile_cache_size = s_tiles ? next_capacity : TILE_CACHE_SIZE;
  reset_tile_chunk_assembly();
  s_tile_decode_buffer = buffer;
  assign_tile_decode_buffers();
  APP_LOG(APP_LOG_LEVEL_INFO, "Tile geometry %dx%d bytes=%d cache=%d/%d",
          s_tile_width, s_tile_height, s_tile_bytes, active_tile_cache_size(),
          TILE_CACHE_SIZE);
  return true;
}
