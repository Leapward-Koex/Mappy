#include "mappy.h"

// Map, route, location, status chrome, and menu rendering.

static TileRequest s_render_tile_origins[TILE_CACHE_SIZE];
static TileCacheEntry *s_render_tile_entries[TILE_CACHE_SIZE];
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
static int s_last_rotated_log_entry_count = -1;
static int s_last_rotated_log_cols = -1;
static int s_last_rotated_log_rows = -1;
static int s_last_rotated_log_tile_width = -1;
static int s_last_rotated_log_tile_height = -1;

static int rotated_tile_geometry_code(void) {
  if (s_tile_width == 54 && s_tile_height == 63) {
    return 1;
  }
  if (s_tile_width == 72 && s_tile_height == 84) {
    return 2;
  }
  if (s_tile_width == 108 && s_tile_height == 126) {
    return 3;
  }
  return 0;
}
#endif

GColor chrome_bg(void) {
  return s_theme_mode == 2 ? GColorFromHEX(0x12181E) : GColorWhite;
}

GColor chrome_fg(void) {
  return s_theme_mode == 2 ? GColorWhite : GColorFromHEX(0x182321);
}

GColor chrome_border(void) {
  return s_theme_mode == 2 ? GColorFromHEX(0x5A6A70) : GColorFromHEX(0xB6C1BC);
}

GColor chrome_accent(void) {
  if (s_state == AppStateNavigating || s_state == AppStateRouteLoading) {
    return GColorFromHEX(0x1A73E8);
  }
  if (s_state == AppStateRouteError || s_state == AppStateSetupRequired) {
    return GColorFromHEX(0xDA6051);
  }
  return GColorFromHEX(0x19706D);
}


uint8_t tile_fade_order(int px, int py) {
  static const uint8_t bayer8[8][8] = {
    {0, 48, 12, 60, 3, 51, 15, 63},
    {32, 16, 44, 28, 35, 19, 47, 31},
    {8, 56, 4, 52, 11, 59, 7, 55},
    {40, 24, 36, 20, 43, 27, 39, 23},
    {2, 50, 14, 62, 1, 49, 13, 61},
    {34, 18, 46, 30, 33, 17, 45, 29},
    {10, 58, 6, 54, 9, 57, 5, 53},
    {42, 26, 38, 22, 41, 25, 37, 21},
  };
  return bayer8[py & 7][px & 7];
}

static void fill_map_background(GContext *ctx, GColor background) {
  graphics_context_set_fill_color(ctx, background);
  graphics_fill_rect(ctx, s_screen_bounds, 0, GCornerNone);
}

void draw_tile_placeholders(GContext *ctx) {
  if (!s_has_gps || map_orientation_active()) {
    return;
  }

  int count = visible_tile_origins(s_render_tile_origins, TILE_CACHE_SIZE);
  for (int i = 0; i < count; i++) {
    int32_t world_x = s_render_tile_origins[i].world_x;
    int32_t world_y = s_render_tile_origins[i].world_y;
    TileCacheEntry *entry = find_tile(world_x, world_y,
                                      s_render_tile_origins[i].zoom);
    if (entry && entry->valid) {
      continue;
    }
    GPoint top_left = screen_point_from_viewport_world(world_x, world_y);
    GRect rect = GRect(top_left.x, top_left.y,
                       scaled_length(s_tile_width), scaled_length(s_tile_height));
    graphics_context_set_fill_color(ctx, s_theme_mode == 2 ?
                                    GColorFromHEX(0x202A33) :
                                    GColorFromHEX(0xE8EEE8));
    graphics_fill_rect(ctx, rect, 0, GCornerNone);
  }
}

bool tile_animation_draws_pixel(int px, int py, uint16_t progress_q8) {
  if (progress_q8 >= 256) {
    return true;
  }
  return (uint16_t)(tile_fade_order(px, py) * 4) < progress_q8;
}

int32_t tile_zoomed_local_coord_q8(int local_px, int tile_pixels, uint16_t scale_q8) {
  int32_t center_q8 = ((int32_t)tile_pixels * 256) / 2;
  int32_t local_q8 = ((int32_t)local_px * 256) - center_q8;
  return center_q8 + ((local_q8 * scale_q8) / 256);
}

static int32_t trig_ratio_to_nearest_int(int32_t value) {
#if TRIG_MAX_RATIO == (1 << TRIG_RATIO_SHIFT)
  const int32_t half = (int32_t)1 << (TRIG_RATIO_SHIFT - 1);
  if (value >= 0) {
    return (value + half) >> TRIG_RATIO_SHIFT;
  }
  return -(((-value) + half) >> TRIG_RATIO_SHIFT);
#else
  const int32_t half = TRIG_MAX_RATIO / 2;
  if (value >= 0) {
    return (value + half) / TRIG_MAX_RATIO;
  }
  return -(((-value) + half) / TRIG_MAX_RATIO);
#endif
}

static int32_t q8_to_nearest_int(int32_t value) {
  if (value >= 0) {
    return (value + 128) / 256;
  }
  return -((-value + 128) / 256);
}

static int visible_tile_entry_index(TileCacheEntry **entries, int entry_count,
                                    int32_t world_x, int32_t world_y,
                                    int8_t zoom) {
  int32_t origin_x = floor_div_i32(world_x, s_tile_width) * s_tile_width;
  int32_t origin_y = floor_div_i32(world_y, s_tile_height) * s_tile_height;
  for (int i = 0; i < entry_count; i++) {
    TileCacheEntry *entry = entries[i];
    if (entry && entry->valid && tile_matches(entry, origin_x, origin_y, zoom)) {
      return i;
    }
  }
  return -1;
}

static bool sample_visible_tile_palette_index(TileCacheEntry **entries,
                                              int entry_count,
                                              const uint16_t *animation_progress_q8,
                                              const uint16_t *animation_scale_q8,
                                              int32_t world_x,
                                              int32_t world_y,
                                              int8_t zoom,
                                              uint8_t *palette_index) {
  int entry_index = visible_tile_entry_index(entries, entry_count, world_x,
                                             world_y, zoom);
  if (entry_index < 0) {
    return false;
  }

  TileCacheEntry *entry = entries[entry_index];
  int local_x = (int)(world_x - entry->world_x);
  int local_y = (int)(world_y - entry->world_y);
  if (local_x < 0 || local_x >= s_tile_width ||
      local_y < 0 || local_y >= s_tile_height) {
    return false;
  }

  int sample_x = local_x;
  int sample_y = local_y;
  uint16_t progress_q8 =
      animation_progress_q8 ? animation_progress_q8[entry_index] : 256;
  if (progress_q8 < 256) {
    uint16_t scale_q8 =
        animation_scale_q8 ? animation_scale_q8[entry_index] : 256;
    if (scale_q8 < 256) {
      int32_t center_x_q8 = ((int32_t)s_tile_width * 256) / 2;
      int32_t center_y_q8 = ((int32_t)s_tile_height * 256) / 2;
      int32_t local_x_q8 = ((int32_t)local_x * 256) - center_x_q8;
      int32_t local_y_q8 = ((int32_t)local_y * 256) - center_y_q8;
      sample_x = q8_to_nearest_int(center_x_q8 +
                                   (local_x_q8 * 256) / scale_q8);
      sample_y = q8_to_nearest_int(center_y_q8 +
                                   (local_y_q8 * 256) / scale_q8);
      if (sample_x < 0 || sample_x >= s_tile_width ||
          sample_y < 0 || sample_y >= s_tile_height) {
        return false;
      }
    }
    if (!tile_animation_draws_pixel(sample_x, sample_y, progress_q8)) {
      return false;
    }
  }

  int pixel_index = sample_y * s_tile_width + sample_x;
  uint8_t packed = entry->decoded[pixel_index / 2];
  *palette_index = (pixel_index & 1) ? (packed >> 4) : (packed & 0x0f);
  return true;
}

typedef struct {
  TileCacheEntry *entry;
  uint16_t progress_q8;
  uint16_t scale_q8;
} RotatedTileCell;

typedef struct {
  int32_t min_x;
  int32_t min_y;
  int cols;
  int rows;
  bool has_animation;
  RotatedTileCell cells[TILE_CACHE_SIZE];
} RotatedTileLookup;

static RotatedTileLookup s_rotated_tile_lookup;

static bool prepare_rotated_tile_lookup(TileCacheEntry **entries, int entry_count,
                                        RotatedTileLookup *lookup) {
  if (!lookup) {
    return false;
  }

  int32_t min_x = INT32_MAX;
  int32_t max_x = INT32_MIN;
  int32_t min_y = INT32_MAX;
  int32_t max_y = INT32_MIN;
  int valid_count = 0;
  for (int i = 0; i < entry_count; i++) {
    TileCacheEntry *entry = entries[i];
    if (!entry || !entry->valid) {
      continue;
    }
    if (entry->world_x < min_x) {
      min_x = entry->world_x;
    }
    if (entry->world_x > max_x) {
      max_x = entry->world_x;
    }
    if (entry->world_y < min_y) {
      min_y = entry->world_y;
    }
    if (entry->world_y > max_y) {
      max_y = entry->world_y;
    }
    valid_count++;
  }

  lookup->min_x = min_x;
  lookup->min_y = min_y;
  lookup->cols = 0;
  lookup->rows = 0;
  lookup->has_animation = false;
  memset(lookup->cells, 0, sizeof(lookup->cells));
  if (valid_count == 0) {
    return true;
  }

  int cols = (int)((max_x - min_x) / s_tile_width) + 1;
  int rows = (int)((max_y - min_y) / s_tile_height) + 1;
  if (cols <= 0 || rows <= 0 || cols * rows > TILE_CACHE_SIZE) {
    return false;
  }

  lookup->cols = cols;
  lookup->rows = rows;
  for (int i = 0; i < entry_count; i++) {
    TileCacheEntry *entry = entries[i];
    if (!entry || !entry->valid) {
      continue;
    }

    entry->last_used = ++s_access_counter;
    uint16_t progress_q8 = 256;
    uint16_t scale_q8 = 256;
    if (entry->animation_active) {
      progress_q8 = tile_animation_progress_q8(entry);
      if (progress_q8 >= 256) {
        complete_tile_animation(entry);
        progress_q8 = 256;
      } else {
        lookup->has_animation = true;
        if (entry->animation_mode == TILE_ANIMATION_FADE_ZOOM) {
          uint16_t eased_q8 = tile_animation_eased_q8(progress_q8);
          scale_q8 = TILE_ANIMATION_ZOOM_START_Q8 +
              (((256 - TILE_ANIMATION_ZOOM_START_Q8) * eased_q8) / 256);
        }
      }
    }

    int col = (int)((entry->world_x - min_x) / s_tile_width);
    int row = (int)((entry->world_y - min_y) / s_tile_height);
    if (col < 0 || col >= cols || row < 0 || row >= rows) {
      return false;
    }

    RotatedTileCell *cell = &lookup->cells[row * cols + col];
    cell->entry = entry;
    cell->progress_q8 = progress_q8;
    cell->scale_q8 = scale_q8;
  }
  return true;
}

#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
static void log_rotated_render_signature(int entry_count,
                                         const RotatedTileLookup *lookup) {
  if (!lookup) {
    return;
  }
  if (entry_count == s_last_rotated_log_entry_count &&
      lookup->cols == s_last_rotated_log_cols &&
      lookup->rows == s_last_rotated_log_rows &&
      s_tile_width == s_last_rotated_log_tile_width &&
      s_tile_height == s_last_rotated_log_tile_height) {
    return;
  }

  s_last_rotated_log_entry_count = entry_count;
  s_last_rotated_log_cols = lookup->cols;
  s_last_rotated_log_rows = lookup->rows;
  s_last_rotated_log_tile_width = s_tile_width;
  s_last_rotated_log_tile_height = s_tile_height;
  int signature = (entry_count & 0x3f) |
      ((lookup->cols & 0x3f) << 6) |
      ((lookup->rows & 0x3f) << 12) |
      ((rotated_tile_geometry_code() & 0x0f) << 18) |
      ((active_tile_cache_size() & 0x3f) << 22);
  APP_LOG(APP_LOG_LEVEL_INFO,
          "Rotated render entries=%d lookup=%dx%d tile=%dx%d cache=%d bearing=%ld sig=%d",
          entry_count, lookup->cols, lookup->rows, s_tile_width, s_tile_height,
          active_tile_cache_size(), (long)active_map_bearing_degrees(), signature);
}
#endif

static inline bool sample_rotated_tile_lookup_palette_index(
    const RotatedTileLookup *lookup, int col, int row, int local_x,
    int local_y, uint8_t *palette_index) {
  if (!lookup || lookup->cols <= 0 || lookup->rows <= 0) {
    return false;
  }

  if (col < 0 || col >= lookup->cols || row < 0 || row >= lookup->rows ||
      local_x < 0 || local_x >= s_tile_width ||
      local_y < 0 || local_y >= s_tile_height) {
    return false;
  }

  const RotatedTileCell *cell = &lookup->cells[row * lookup->cols + col];
  TileCacheEntry *entry = cell->entry;
  if (!entry || !entry->valid) {
    return false;
  }

  int sample_x = local_x;
  int sample_y = local_y;
  if (lookup->has_animation && cell->progress_q8 < 256) {
    if (cell->scale_q8 < 256) {
      int32_t center_x_q8 = ((int32_t)s_tile_width * 256) / 2;
      int32_t center_y_q8 = ((int32_t)s_tile_height * 256) / 2;
      int32_t local_x_q8 = ((int32_t)local_x * 256) - center_x_q8;
      int32_t local_y_q8 = ((int32_t)local_y * 256) - center_y_q8;
      sample_x = q8_to_nearest_int(center_x_q8 +
                                   (local_x_q8 * 256) / cell->scale_q8);
      sample_y = q8_to_nearest_int(center_y_q8 +
                                   (local_y_q8 * 256) / cell->scale_q8);
      if (sample_x < 0 || sample_x >= s_tile_width ||
          sample_y < 0 || sample_y >= s_tile_height) {
        return false;
      }
    }
    if (!tile_animation_draws_pixel(sample_x, sample_y, cell->progress_q8)) {
      return false;
    }
  }

  int pixel_index = sample_y * s_tile_width + sample_x;
  uint8_t packed = entry->decoded[pixel_index / 2];
  *palette_index = (pixel_index & 1) ? (packed >> 4) : (packed & 0x0f);
  return true;
}

static inline void rotated_lookup_position(const RotatedTileLookup *lookup,
                                           int32_t world_x, int32_t world_y,
                                           int *col, int *row,
                                           int *local_x, int *local_y) {
  int32_t dx = world_x - lookup->min_x;
  int32_t dy = world_y - lookup->min_y;
  *col = floor_div_i32(dx, s_tile_width);
  *row = floor_div_i32(dy, s_tile_height);
  *local_x = (int)(dx - (int32_t)(*col) * s_tile_width);
  *local_y = (int)(dy - (int32_t)(*row) * s_tile_height);
}

static inline void advance_rotated_lookup_axis(int delta, int tile_size,
                                               int *cell_index, int *local) {
  // At 1:1 scale, one screen pixel can advance by at most one world pixel.
  *local += delta;
  if (*local < 0) {
    *local += tile_size;
    (*cell_index)--;
  } else if (*local >= tile_size) {
    *local -= tile_size;
    (*cell_index)++;
  }
}

static void draw_rotated_tiles_framebuffer_linear(uint8_t *framebuffer_data,
                                                  int16_t bytes_per_row,
                                                  uint8_t background_argb,
                                                  const uint8_t *palette_argb,
                                                  TileCacheEntry **entries,
                                                  int entry_count,
                                                  int screen_w,
                                                  int screen_h,
                                                  int center_x,
                                                  int center_y,
                                                  int32_t sin_value,
                                                  int32_t cos_value) {
  uint16_t animation_progress_q8[TILE_CACHE_SIZE];
  uint16_t animation_scale_q8[TILE_CACHE_SIZE];
  for (int i = 0; i < entry_count; i++) {
    TileCacheEntry *entry = entries[i];
    animation_progress_q8[i] = 256;
    animation_scale_q8[i] = 256;
    if (!entry || !entry->valid) {
      continue;
    }

    entry->last_used = ++s_access_counter;
    if (entry->animation_active) {
      uint16_t progress_q8 = tile_animation_progress_q8(entry);
      if (progress_q8 >= 256) {
        complete_tile_animation(entry);
      } else {
        animation_progress_q8[i] = progress_q8;
        if (entry->animation_mode == TILE_ANIMATION_FADE_ZOOM) {
          uint16_t eased_q8 = tile_animation_eased_q8(progress_q8);
          animation_scale_q8[i] = TILE_ANIMATION_ZOOM_START_Q8 +
              (((256 - TILE_ANIMATION_ZOOM_START_Q8) * eased_q8) / 256);
        }
      }
    }
  }

  for (int screen_y = 0; screen_y < screen_h; screen_y++) {
    int32_t sy = screen_y - center_y;
    int32_t sx = -center_x;
    int32_t world_x_num = sx * cos_value - sy * sin_value;
    int32_t world_y_num = sx * sin_value + sy * cos_value;
    int32_t viewport_x = render_viewport_x();
    int32_t viewport_y = render_viewport_y();
    uint8_t *dst_row = framebuffer_data + (screen_y * bytes_per_row);
    for (int screen_x = 0; screen_x < screen_w; screen_x++) {
      int32_t world_x = viewport_x + trig_ratio_to_nearest_int(world_x_num);
      int32_t world_y = viewport_y + trig_ratio_to_nearest_int(world_y_num);
      uint8_t palette_index;
      if (sample_visible_tile_palette_index(entries, entry_count,
                                            animation_progress_q8,
                                            animation_scale_q8,
                                            world_x, world_y, s_viewport_zoom,
                                            &palette_index)) {
        dst_row[screen_x] = palette_argb[palette_index & 0x0f];
      } else {
        dst_row[screen_x] = background_argb;
      }
      world_x_num += cos_value;
      world_y_num += sin_value;
    }
  }
}

static void draw_rotated_tiles_framebuffer_sampled(uint8_t *framebuffer_data,
                                                   int16_t bytes_per_row,
                                                   uint8_t background_argb,
                                                   const uint8_t *palette_argb,
                                                   TileCacheEntry **entries,
                                                   int entry_count,
                                                   int screen_w,
                                                   int screen_h,
                                                   int center_x,
                                                   int center_y,
                                                   int32_t sin_value,
                                                   int32_t cos_value) {
  RotatedTileLookup *lookup = &s_rotated_tile_lookup;
  if (!prepare_rotated_tile_lookup(entries, entry_count, lookup)) {
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Rotated render lookup fallback entries=%d tile=%dx%d cache=%d",
            entry_count, s_tile_width, s_tile_height, active_tile_cache_size());
    draw_rotated_tiles_framebuffer_linear(framebuffer_data, bytes_per_row,
                                          background_argb, palette_argb,
                                          entries, entry_count, screen_w,
                                          screen_h, center_x, center_y,
                                          sin_value, cos_value);
    return;
  }
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  log_rotated_render_signature(entry_count, lookup);
#endif
  if (lookup->cols <= 0 || lookup->rows <= 0) {
    for (int screen_y = 0; screen_y < screen_h; screen_y++) {
      memset(framebuffer_data + (screen_y * bytes_per_row), background_argb,
             screen_w);
    }
    return;
  }

  for (int screen_y = 0; screen_y < screen_h; screen_y++) {
    int32_t sy = screen_y - center_y;
    int32_t sx = -center_x;
    int32_t world_x_num = sx * cos_value - sy * sin_value;
    int32_t world_y_num = sx * sin_value + sy * cos_value;
    uint8_t *dst_row = framebuffer_data + (screen_y * bytes_per_row);
    int32_t viewport_x = render_viewport_x();
    int32_t viewport_y = render_viewport_y();
    int32_t world_x = viewport_x + trig_ratio_to_nearest_int(world_x_num);
    int32_t world_y = viewport_y + trig_ratio_to_nearest_int(world_y_num);
    int col;
    int row;
    int local_x;
    int local_y;
    rotated_lookup_position(lookup, world_x, world_y, &col, &row,
                            &local_x, &local_y);
    for (int screen_x = 0; screen_x < screen_w; screen_x++) {
      uint8_t palette_index;
      if (sample_rotated_tile_lookup_palette_index(lookup, col, row,
                                                   local_x, local_y,
                                                   &palette_index)) {
        dst_row[screen_x] = palette_argb[palette_index & 0x0f];
      } else {
        dst_row[screen_x] = background_argb;
      }
      world_x_num += cos_value;
      world_y_num += sin_value;
      int32_t next_world_x = viewport_x + trig_ratio_to_nearest_int(world_x_num);
      int32_t next_world_y = viewport_y + trig_ratio_to_nearest_int(world_y_num);
      advance_rotated_lookup_axis((int)(next_world_x - world_x), s_tile_width,
                                  &col, &local_x);
      advance_rotated_lookup_axis((int)(next_world_y - world_y), s_tile_height,
                                  &row, &local_y);
      world_x = next_world_x;
      world_y = next_world_y;
    }
  }
}

static void draw_tile_row_unscaled(uint8_t *dst_row, const uint8_t *decoded,
                                   int pixel_index, int draw_w,
                                   const uint8_t *palette_argb) {
  int col = 0;
  if ((pixel_index & 1) && draw_w > 0) {
    uint8_t packed = decoded[pixel_index / 2];
    dst_row[col++] = palette_argb[packed >> 4];
    pixel_index++;
  }

  const uint8_t *src = decoded + (pixel_index / 2);
  while (col + 1 < draw_w) {
    uint8_t packed = *src++;
    dst_row[col++] = palette_argb[packed & 0x0f];
    dst_row[col++] = palette_argb[packed >> 4];
  }
  if (col < draw_w) {
    uint8_t packed = *src;
    dst_row[col] = palette_argb[packed & 0x0f];
  }
}

bool draw_tiles_framebuffer_fast(GContext *ctx, const GColor *palette,
                                 TileCacheEntry **entries, int entry_count,
                                 uint8_t background_argb) {
  if (!ctx || !palette || !entries || entry_count <= 0 ||
      s_transient_zoom_scale_q8 != TRANSIENT_SCALE_Q8_ONE) {
    return false;
  }

  for (int i = 0; i < entry_count; i++) {
    TileCacheEntry *entry = entries[i];
    if (!entry || !entry->valid) {
      continue;
    }
    if (entry->animation_active) {
      if (tile_animation_progress_q8(entry) >= 256) {
        complete_tile_animation(entry);
      }
    }
  }

  GBitmap *framebuffer = graphics_capture_frame_buffer(ctx);
  if (!framebuffer) {
    return false;
  }
  if (gbitmap_get_format(framebuffer) != GBitmapFormat8Bit) {
    graphics_release_frame_buffer(ctx, framebuffer);
    return false;
  }

  uint8_t *framebuffer_data = gbitmap_get_data(framebuffer);
  int16_t bytes_per_row = gbitmap_get_bytes_per_row(framebuffer);
  if (!framebuffer_data || bytes_per_row <= 0) {
    graphics_release_frame_buffer(ctx, framebuffer);
    return false;
  }

  uint8_t palette_argb[16];
  for (int i = 0; i < 16; i++) {
    palette_argb[i] = palette[i].argb;
  }

  const int screen_w = s_screen_bounds.size.w;
  const int screen_h = s_screen_bounds.size.h;
  const int center_x = screen_w / 2;
  const int center_y = screen_h / 2;
  bool rotated = map_orientation_active();
  int32_t sin_value = 0;
  int32_t cos_value = TRIG_MAX_RATIO;
  if (rotated) {
    int32_t angle = active_map_bearing_angle();
    sin_value = sin_lookup(angle);
    cos_value = cos_lookup(angle);
    draw_rotated_tiles_framebuffer_sampled(framebuffer_data, bytes_per_row,
                                           background_argb, palette_argb,
                                           entries, entry_count, screen_w,
                                           screen_h, center_x, center_y,
                                           sin_value, cos_value);
    graphics_release_frame_buffer(ctx, framebuffer);
    return true;
  }

  for (int i = 0; i < entry_count; i++) {
    TileCacheEntry *entry = entries[i];
    if (!entry || !entry->valid) {
      continue;
    }
    if (entry->animation_active) {
      continue;
    }

    entry->last_used = ++s_access_counter;

    int dst_x = center_x + (int)(entry->world_x - render_viewport_x());
    int dst_y = center_y + (int)(entry->world_y - render_viewport_y());
    int src_x = 0;
    int src_y = 0;
    int draw_w = s_tile_width;
    int draw_h = s_tile_height;

    if (dst_x < 0) {
      src_x = -dst_x;
      draw_w += dst_x;
      dst_x = 0;
    }
    if (dst_y < 0) {
      src_y = -dst_y;
      draw_h += dst_y;
      dst_y = 0;
    }
    if (dst_x + draw_w > screen_w) {
      draw_w = screen_w - dst_x;
    }
    if (dst_y + draw_h > screen_h) {
      draw_h = screen_h - dst_y;
    }
    if (draw_w <= 0 || draw_h <= 0) {
      continue;
    }

    for (int row = 0; row < draw_h; row++) {
      int pixel_index = (src_y + row) * s_tile_width + src_x;
      uint8_t *dst_row = framebuffer_data + ((dst_y + row) * bytes_per_row) + dst_x;
      draw_tile_row_unscaled(dst_row, entry->decoded, pixel_index, draw_w, palette_argb);
    }
  }

  graphics_release_frame_buffer(ctx, framebuffer);
  return true;
}

void draw_tile_entry_slow(GContext *ctx, TileCacheEntry *entry, const GColor *palette) {
  if (!ctx || !entry || !palette || !entry->valid) {
    return;
  }

  entry->last_used = ++s_access_counter;
  uint16_t progress_q8 = tile_animation_progress_q8(entry);
  if (entry->animation_active && progress_q8 >= 256) {
    complete_tile_animation(entry);
    progress_q8 = 256;
  }
  uint16_t zoom_eased_q8 = tile_animation_eased_q8(progress_q8);
  uint16_t scale_q8 = 256;
  if (entry->animation_active && entry->animation_mode == TILE_ANIMATION_FADE_ZOOM) {
    scale_q8 = TILE_ANIMATION_ZOOM_START_Q8 +
        (((256 - TILE_ANIMATION_ZOOM_START_Q8) * zoom_eased_q8) / 256);
  }

  for (int py = 0; py < s_tile_height; py++) {
    for (int px = 0; px < s_tile_width; px++) {
      if (entry->animation_active && !tile_animation_draws_pixel(px, py, progress_q8)) {
        continue;
      }
      int32_t world_x = entry->world_x + px;
      int32_t world_y = entry->world_y + py;
      if (scale_q8 < 256) {
        world_x = entry->world_x +
            (tile_zoomed_local_coord_q8(px, s_tile_width, scale_q8) / 256);
        world_y = entry->world_y +
            (tile_zoomed_local_coord_q8(py, s_tile_height, scale_q8) / 256);
      }
      GPoint point = screen_point_from_viewport_world(world_x, world_y);
      if (point.x < 0 || point.x >= s_screen_bounds.size.w ||
          point.y < 0 || point.y >= s_screen_bounds.size.h) {
        continue;
      }
      int pixel_index = py * s_tile_width + px;
      uint8_t packed = entry->decoded[pixel_index / 2];
      uint8_t palette_index = (pixel_index & 1) ? (packed >> 4) : (packed & 0x0f);
      graphics_context_set_fill_color(ctx, palette[palette_index & 0x0f]);
      graphics_fill_rect(ctx, GRect(point.x, point.y, scaled_length(1),
                                    scaled_length(1)), 0, GCornerNone);
    }
  }
}

void draw_tiles(GContext *ctx, GColor background, bool fill_background) {
  if (!s_tiles) {
    if (fill_background) {
      fill_map_background(ctx, background);
    }
    return;
  }
  const GColor *palette = s_theme_mode == 2 ? s_night_palette : s_day_palette;
  bool render_full_cache = s_gps_smoothing_active &&
      s_gps_smoothing_mode == GPS_SMOOTHING_MAP;
  int origin_count = render_full_cache ? active_tile_cache_size() :
      visible_tile_origins(s_render_tile_origins, TILE_CACHE_SIZE);
  if (origin_count <= 0) {
    if (fill_background) {
      fill_map_background(ctx, background);
    }
    return;
  }

  if (render_full_cache) {
    for (int i = 0; i < origin_count; i++) {
      s_render_tile_entries[i] = &s_tiles[i];
    }
  } else {
    for (int i = 0; i < origin_count; i++) {
      s_render_tile_entries[i] = find_tile(s_render_tile_origins[i].world_x,
                                           s_render_tile_origins[i].world_y,
                                           s_render_tile_origins[i].zoom);
    }
  }

  if (draw_tiles_framebuffer_fast(ctx, palette, s_render_tile_entries,
                                  origin_count, background.argb)) {
    if (!map_orientation_active()) {
      for (int i = 0; i < origin_count; i++) {
        TileCacheEntry *entry = s_render_tile_entries[i];
        if (entry && entry->valid && entry->animation_active) {
          draw_tile_entry_slow(ctx, entry, palette);
        }
      }
    }
    return;
  }

  if (fill_background) {
    fill_map_background(ctx, background);
  }
  for (int i = 0; i < origin_count; i++) {
    TileCacheEntry *entry = s_render_tile_entries[i];
    if (!entry || !entry->valid) {
      continue;
    }
    draw_tile_entry_slow(ctx, entry, palette);
  }
}

static int32_t render_trig_ratio_to_int(int64_t value) {
#if TRIG_MAX_RATIO == (1 << TRIG_RATIO_SHIFT)
  if (value >= 0) {
    return (int32_t)(value >> TRIG_RATIO_SHIFT);
  }
  return -(int32_t)((-value) >> TRIG_RATIO_SHIFT);
#else
  return (int32_t)(value / TRIG_MAX_RATIO);
#endif
}

static void build_map_render_transform(MapRenderTransform *transform) {
  transform->viewport_x = render_viewport_x();
  transform->viewport_y = render_viewport_y();
  transform->center_x = s_screen_bounds.size.w / 2;
  transform->center_y = s_screen_bounds.size.h / 2;
  transform->scale_q8 = s_transient_zoom_scale_q8;
  transform->bearing_centi_degrees = active_map_bearing_centi_degrees();
  if (transform->bearing_centi_degrees == 0) {
    transform->sin_value = 0;
    transform->cos_value = TRIG_MAX_RATIO;
  } else {
    int32_t angle = active_map_bearing_angle();
    transform->sin_value = sin_lookup(angle);
    transform->cos_value = cos_lookup(angle);
  }
}

static GPoint map_transform_point(const MapRenderTransform *transform,
                                  int32_t world_x, int32_t world_y,
                                  int8_t source_zoom) {
  int32_t dx = scale_world_to_zoom(world_x, source_zoom, s_viewport_zoom) -
      transform->viewport_x;
  int32_t dy = scale_world_to_zoom(world_y, source_zoom, s_viewport_zoom) -
      transform->viewport_y;
  int32_t screen_dx = dx;
  int32_t screen_dy = dy;
  if (transform->bearing_centi_degrees != 0) {
    screen_dx = render_trig_ratio_to_int(
        (int64_t)dx * transform->cos_value +
        (int64_t)dy * transform->sin_value);
    screen_dy = render_trig_ratio_to_int(
        -(int64_t)dx * transform->sin_value +
        (int64_t)dy * transform->cos_value);
  }
  screen_dx = screen_dx * transform->scale_q8 / TRANSIENT_SCALE_Q8_ONE;
  screen_dy = screen_dy * transform->scale_q8 / TRANSIENT_SCALE_Q8_ONE;
  return GPoint((int16_t)clamp_i32_to_i16(transform->center_x + screen_dx),
                (int16_t)clamp_i32_to_i16(transform->center_y + screen_dy));
}

typedef struct {
  int32_t active_generation;
  int32_t detail_center_x;
  int32_t detail_center_y;
  int32_t gps_world_x;
  int32_t gps_world_y;
  uint32_t context;
} RouteProjectionCacheKey;

typedef struct {
  bool initialized;
  RouteProjectionCacheKey key;
  RouteProjection projection;
} RouteProjectionCache;

static RouteProjectionCache s_route_projection_cache;

static RouteProjection cached_route_projection(const RoutePoint *points,
                                               uint16_t point_count,
                                               int8_t route_zoom,
                                               bool detail_route) {
  bool gps_fresh = gps_fresh_for_progress();
  int32_t gps_world_x = display_gps_world_x();
  int32_t gps_world_y = display_gps_world_y();
  RouteProjectionCacheKey key = {
    .active_generation = detail_route ? s_route_detail_generation :
        s_route_generation,
    .detail_center_x = detail_route ? s_route_detail_center_x : 0,
    .detail_center_y = detail_route ? s_route_detail_center_y : 0,
    .gps_world_x = gps_world_x,
    .gps_world_y = gps_world_y,
    .context = point_count |
        ((uint32_t)(uint8_t)route_zoom << 8) |
        ((uint32_t)(uint8_t)s_viewport_zoom << 15) |
        ((uint32_t)(uint8_t)s_gps_zoom << 20) |
        ((uint32_t)(gps_fresh ? 1 : 0) << 25) |
        ((uint32_t)(detail_route ? 1 : 0) << 26),
  };
  if (s_route_projection_cache.initialized &&
      memcmp(&s_route_projection_cache.key, &key, sizeof(key)) == 0) {
    return s_route_projection_cache.projection;
  }

  s_route_projection_cache.initialized = true;
  s_route_projection_cache.key = key;
  s_route_projection_cache.projection = (RouteProjection) {
    .valid = false,
    .progress_px = 0,
    .distance_sq = INT64_MAX,
    .segment_index = 0,
    .segment_t_q16 = 0,
  };
  if (gps_fresh) {
    int32_t route_gps_x = scale_world_to_zoom(gps_world_x, s_gps_zoom,
                                              route_zoom);
    int32_t route_gps_y = scale_world_to_zoom(gps_world_y, s_gps_zoom,
                                              route_zoom);
    s_route_projection_cache.projection = project_route_points_position(
        points, point_count, route_gps_x, route_gps_y);
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
    fixture_perf_route_projection_recompute();
#endif
  }
  return s_route_projection_cache.projection;
}

static bool route_clip_edge_q16(int32_t p, int32_t q,
                                int32_t *t0_q16, int32_t *t1_q16) {
  if (p == 0) {
    return q >= 0;
  }

  int32_t r_q16 = (int32_t)(((int64_t)q * 65536) / p);
  if (p < 0) {
    if (r_q16 > *t1_q16) {
      return false;
    }
    if (r_q16 > *t0_q16) {
      *t0_q16 = r_q16;
    }
    return true;
  }

  if (r_q16 < *t0_q16) {
    return false;
  }
  if (r_q16 < *t1_q16) {
    *t1_q16 = r_q16;
  }
  return true;
}

static bool __attribute__((noinline)) clip_route_segment_to_screen_q16(
    GPoint start, GPoint end, int32_t padding,
    int32_t *t0_q16, int32_t *t1_q16) {
  int32_t dx = end.x - start.x;
  int32_t dy = end.y - start.y;
  int32_t min_x = -padding;
  int32_t min_y = -padding;
  int32_t max_x = s_screen_bounds.size.w + padding;
  int32_t max_y = s_screen_bounds.size.h + padding;

  *t0_q16 = 0;
  *t1_q16 = 65536;
  return route_clip_edge_q16(-dx, start.x - min_x, t0_q16, t1_q16) &&
      route_clip_edge_q16(dx, max_x - start.x, t0_q16, t1_q16) &&
      route_clip_edge_q16(-dy, start.y - min_y, t0_q16, t1_q16) &&
      route_clip_edge_q16(dy, max_y - start.y, t0_q16, t1_q16);
}

static int32_t first_spaced_distance_at_or_after(int32_t next_distance,
                                                 int32_t target_distance,
                                                 int32_t spacing) {
  if (next_distance >= target_distance) {
    return next_distance;
  }
  int32_t delta = target_distance - next_distance;
  int32_t steps = (delta + spacing - 1) / spacing;
  return next_distance + steps * spacing;
}

static void draw_walking_route_dot(GContext *ctx, GPoint point) {
  graphics_context_set_fill_color(ctx, GColorWhite);
  graphics_fill_circle(ctx, point, WALK_ROUTE_DOT_HALO_RADIUS);
  graphics_context_set_fill_color(ctx, GColorFromHEX(0x1A73E8));
  graphics_fill_circle(ctx, point, WALK_ROUTE_DOT_RADIUS);
}

static GPoint __attribute__((noinline)) route_point_at_fraction(
    GPoint start, GPoint end, int32_t t_q16) {
  int32_t x = start.x +
      (int32_t)(((int64_t)(end.x - start.x) * t_q16) / 65536);
  int32_t y = start.y +
      (int32_t)(((int64_t)(end.y - start.y) * t_q16) / 65536);
  return GPoint((int16_t)clamp_i32_to_i16(x),
                (int16_t)clamp_i32_to_i16(y));
}

static bool route_visual_projection_on_route(
    const GPoint *route_points, uint16_t point_count,
    RouteProjection projection, const MapRenderTransform *transform) {
  if (!projection.valid || point_count < 2 ||
      projection.segment_index >= point_count - 1) {
    return false;
  }

  GPoint gps_point = map_transform_point(transform, display_gps_world_x(),
                                         display_gps_world_y(), s_gps_zoom);
  GPoint projected_point = route_point_at_fraction(
      route_points[projection.segment_index],
      route_points[projection.segment_index + 1],
      (int32_t)projection.segment_t_q16);
  int64_t off_x = (int64_t)gps_point.x - projected_point.x;
  int64_t off_y = (int64_t)gps_point.y - projected_point.y;
  int64_t distance_sq = off_x * off_x + off_y * off_y;
  int64_t threshold_sq =
      (int64_t)ROUTE_VISUAL_OFF_ROUTE_PX * ROUTE_VISUAL_OFF_ROUTE_PX;
  if (distance_sq > threshold_sq) {
    return false;
  }

  return true;
}

static int32_t route_visual_cutoff_px(const GPoint *route_points,
                                      RouteProjection projection) {
  int32_t cumulative_distance = 0;
  for (uint16_t i = 1; i <= projection.segment_index + 1; i++) {
    GPoint start = route_points[i - 1];
    GPoint end = route_points[i];
    int32_t dx = end.x - start.x;
    int32_t dy = end.y - start.y;
    int32_t segment_len = approx_segment_length_px(dx, dy);
    if (segment_len <= 0) {
      continue;
    }
    if (i - 1 == projection.segment_index) {
      int32_t segment_progress = (int32_t)(
          ((int64_t)segment_len * projection.segment_t_q16) / 65536);
      return saturating_add_i32(cumulative_distance, segment_progress);
    }
    cumulative_distance = saturating_add_i32(cumulative_distance, segment_len);
  }
  return cumulative_distance;
}

static void draw_walking_route_dots(GContext *ctx, const GPoint *route_points,
                                    uint16_t point_count, bool has_cutoff,
                                    int32_t cutoff_px) {
  int32_t cumulative_distance = 0;
  int32_t next_dot_distance = WALK_ROUTE_DOT_SPACING_PX / 2;

  for (uint16_t i = 1; i < point_count; i++) {
    GPoint start = route_points[i - 1];
    GPoint end = route_points[i];
    int32_t dx = end.x - start.x;
    int32_t dy = end.y - start.y;
    int32_t segment_len = approx_segment_length_px(dx, dy);
    if (segment_len <= 0) {
      continue;
    }

    int32_t segment_start = cumulative_distance;
    int32_t segment_end = cumulative_distance + segment_len;
    int32_t visible_start = segment_start;
    int32_t visible_end = segment_end;
    int32_t t0_q16;
    int32_t t1_q16;
    bool visible = clip_route_segment_to_screen_q16(
        start, end, WALK_ROUTE_DOT_HALO_RADIUS, &t0_q16, &t1_q16);
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
    fixture_perf_route_segment(visible);
#endif
    if (visible) {
      visible_start += (int32_t)(((int64_t)segment_len * t0_q16) / 65536);
      visible_end = segment_start +
          (int32_t)(((int64_t)segment_len * t1_q16) / 65536);
      if (has_cutoff && visible_start <= cutoff_px) {
        visible_start = cutoff_px == INT32_MAX ? INT32_MAX : cutoff_px + 1;
      }
      next_dot_distance = first_spaced_distance_at_or_after(
          next_dot_distance, visible_start, WALK_ROUTE_DOT_SPACING_PX);
      while (next_dot_distance <= visible_end) {
        int32_t local_distance = next_dot_distance - segment_start;
        int32_t t_q16 = (int32_t)(((int64_t)local_distance * 65536) / segment_len);
        int32_t x = start.x + (int32_t)(((int64_t)dx * t_q16) / 65536);
        int32_t y = start.y + (int32_t)(((int64_t)dy * t_q16) / 65536);
        draw_walking_route_dot(ctx, GPoint((int16_t)clamp_i32_to_i16(x),
                                           (int16_t)clamp_i32_to_i16(y)));
        next_dot_distance += WALK_ROUTE_DOT_SPACING_PX;
      }
    }

    next_dot_distance = first_spaced_distance_at_or_after(
        next_dot_distance, segment_end + 1, WALK_ROUTE_DOT_SPACING_PX);
    cumulative_distance = segment_end;
  }
}

static void __attribute__((noinline)) draw_route_lines(
    GContext *ctx, const GPoint *route_points, uint16_t point_count,
    bool has_cutoff, RouteProjection projection, bool count_segments) {
  for (uint16_t i = 1; i < point_count; i++) {
    GPoint start = route_points[i - 1];
    GPoint end = route_points[i];
    uint16_t segment_index = i - 1;
    if (has_cutoff && segment_index < projection.segment_index) {
      continue;
    }
    if (has_cutoff && segment_index == projection.segment_index) {
      if (projection.segment_t_q16 >= 65536) {
        continue;
      }
      if (projection.segment_t_q16 > 0) {
        start = route_point_at_fraction(
            start, end, (int32_t)projection.segment_t_q16);
      }
    }
    int32_t t0_q16;
    int32_t t1_q16;
    if (!clip_route_segment_to_screen_q16(
            start, end, WALK_ROUTE_DOT_HALO_RADIUS, &t0_q16, &t1_q16)) {
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
      if (count_segments) {
        fixture_perf_route_segment(false);
      }
#endif
      continue;
    }
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
    if (count_segments) {
      fixture_perf_route_segment(true);
    }
#endif
    GPoint clipped_start = route_point_at_fraction(start, end, t0_q16);
    GPoint clipped_end = route_point_at_fraction(start, end, t1_q16);
    graphics_draw_line(ctx, clipped_start, clipped_end);
  }
}

void draw_route(GContext *ctx, const MapRenderTransform *transform) {
  if (s_route_point_count < 2) {
    return;
  }

  const RoutePoint *points = s_route_points;
  uint16_t point_count = s_route_point_count;
  int8_t route_zoom = s_route_zoom;
  bool detail_route = route_detail_available_for_draw();
  if (detail_route) {
    points = s_route_detail_points;
    point_count = s_route_detail_point_count;
    route_zoom = s_route_detail_zoom;
  }

  GPoint route_points[MAX_ROUTE_POINTS];
  for (uint16_t i = 0; i < point_count; i++) {
    route_points[i] = map_transform_point(transform, points[i].world_x,
                                          points[i].world_y, route_zoom);
  }

  RouteProjection projection = cached_route_projection(
      points, point_count, route_zoom, detail_route);
  bool has_cutoff = route_visual_projection_on_route(
      route_points, point_count, projection, transform);
  if (s_active_route_mode == TRAVEL_MODE_WALK) {
    int32_t cutoff_px = has_cutoff ?
        route_visual_cutoff_px(route_points, projection) : 0;
    draw_walking_route_dots(ctx, route_points, point_count, has_cutoff, cutoff_px);
    return;
  }

  graphics_context_set_stroke_color(ctx, GColorWhite);
  graphics_context_set_stroke_width(ctx, 6);
  draw_route_lines(ctx, route_points, point_count, has_cutoff, projection, true);
  graphics_context_set_stroke_color(ctx, GColorFromHEX(0x1A73E8));
  graphics_context_set_stroke_width(ctx, 3);
  draw_route_lines(ctx, route_points, point_count, has_cutoff, projection, false);
  graphics_context_set_stroke_width(ctx, 1);
}

void draw_destination_marker(GContext *ctx,
                             const MapRenderTransform *transform) {
  if (s_route_point_count < 2) {
    return;
  }

  RoutePoint destination = s_route_points[s_route_point_count - 1];
  GPoint point = map_transform_point(transform, destination.world_x,
                                     destination.world_y, s_route_zoom);
  graphics_context_set_stroke_color(ctx, GColorWhite);
  graphics_context_set_stroke_width(ctx, 3);
  graphics_draw_circle(ctx, point, 8);
  graphics_context_set_stroke_width(ctx, 1);
  graphics_context_set_fill_color(ctx, GColorFromHEX(0xDA6051));
  graphics_fill_circle(ctx, point, 5);
  graphics_context_set_stroke_color(ctx, GColorFromHEX(0x7B241C));
  graphics_draw_circle(ctx, point, 5);
}

static int32_t s_location_cone_cached_heading = INT32_MIN;
static GPoint s_location_cone_relative_points[LOCATION_CONE_OUTLINE_SEGMENTS + 1];

static void cache_current_location_cone(int32_t display_heading) {
  if (s_location_cone_cached_heading == display_heading) {
    return;
  }
  s_location_cone_cached_heading = display_heading;
  int32_t start_heading = display_heading - LOCATION_CONE_HALF_ANGLE_DEGREES;
  int32_t step_degrees =
      (LOCATION_CONE_HALF_ANGLE_DEGREES * 2) / LOCATION_CONE_OUTLINE_SEGMENTS;
  for (int i = 0; i <= LOCATION_CONE_OUTLINE_SEGMENTS; i++) {
    int32_t heading = start_heading + step_degrees * i;
    if (i == LOCATION_CONE_OUTLINE_SEGMENTS) {
      heading = display_heading + LOCATION_CONE_HALF_ANGLE_DEGREES;
    }
    s_location_cone_relative_points[i] = point_from_heading(
        GPoint(0, 0), heading, LOCATION_CONE_LENGTH);
  }
}

static GPoint translated_cone_point(GPoint origin, GPoint relative) {
  return GPoint((int16_t)clamp_i32_to_i16(origin.x + relative.x),
                (int16_t)clamp_i32_to_i16(origin.y + relative.y));
}

static void draw_current_location_sector_outline(GContext *ctx, GPoint point,
                                                 GColor color, uint8_t width) {
  GPoint start = translated_cone_point(point, s_location_cone_relative_points[0]);
  GPoint previous = start;

  graphics_context_set_stroke_color(ctx, color);
  graphics_context_set_stroke_width(ctx, width);
  graphics_draw_line(ctx, point, start);
  for (int i = 1; i <= LOCATION_CONE_OUTLINE_SEGMENTS; i++) {
    GPoint next = translated_cone_point(point, s_location_cone_relative_points[i]);
    graphics_draw_line(ctx, previous, next);
    previous = next;
  }
  graphics_draw_line(ctx, point, previous);
}

void draw_current_location_cone(GContext *ctx, GPoint point, int32_t display_heading) {
  cache_current_location_cone(display_heading);
  draw_current_location_sector_outline(ctx, point, GColorWhite,
                                       LOCATION_CONE_OUTLINE_HALO_WIDTH);
  draw_current_location_sector_outline(ctx, point,
                                       GColorFromHEX(LOCATION_BLUE_HEX),
                                       LOCATION_CONE_OUTLINE_WIDTH);
  graphics_context_set_stroke_width(ctx, 1);
}

void draw_current_location(GContext *ctx,
                           const MapRenderTransform *transform) {
  if (!s_has_gps) {
    return;
  }

  GPoint point = map_transform_point(transform, display_gps_world_x(),
                                     display_gps_world_y(), s_gps_zoom);
  int32_t facing_heading;
  if (active_facing_heading_degrees(&facing_heading)) {
    int32_t display_heading = normalize_degrees(
        facing_heading - active_map_bearing_degrees());
    draw_current_location_cone(ctx, point, display_heading);
  }

  graphics_context_set_fill_color(ctx, GColorWhite);
  graphics_fill_circle(ctx, point, LOCATION_HALO_RADIUS);
  graphics_context_set_fill_color(ctx, GColorFromHEX(LOCATION_BLUE_HEX));
  graphics_fill_circle(ctx, point, LOCATION_PUCK_RADIUS);
}

void draw_card(GContext *ctx, GRect rect, GColor fill, GColor border) {
  graphics_context_set_fill_color(ctx, s_theme_mode == 2 ? GColorBlack : GColorFromHEX(0x7D8982));
  graphics_fill_rect(ctx, GRect(rect.origin.x + 1, rect.origin.y + 1, rect.size.w, rect.size.h),
                     4, GCornersAll);
  graphics_context_set_fill_color(ctx, fill);
  graphics_fill_rect(ctx, rect, 4, GCornersAll);
  graphics_context_set_stroke_color(ctx, border);
  graphics_draw_round_rect(ctx, rect, 4);
}

void draw_text_in_rect(GContext *ctx, GRect rect, const char *text, GFont font,
                              GColor color, GTextAlignment alignment) {
  graphics_context_set_text_color(ctx, color);
  graphics_draw_text(ctx, text, font, rect, GTextOverflowModeTrailingEllipsis, alignment, NULL);
}

void copy_text_span(char *dest, size_t dest_size, const char *start, size_t len) {
  if (dest_size == 0) {
    return;
  }
  if (len >= dest_size) {
    len = dest_size - 1;
  }
  memcpy(dest, start, len);
  dest[len] = '\0';
}

void split_status_text(const char *source, char *primary, size_t primary_size,
                              char *secondary, size_t secondary_size) {
  primary[0] = '\0';
  secondary[0] = '\0';
  const char *newline = strchr(source, '\n');
  if (newline) {
    copy_text_span(primary, primary_size, source, (size_t)(newline - source));
    copy_bounded_text(secondary, secondary_size, newline + 1);
    return;
  }

  size_t len = strlen(source);
  if (len <= 27) {
    copy_bounded_text(primary, primary_size, source);
    return;
  }

  size_t split = 27;
  for (size_t i = 27; i > 12; i--) {
    if (source[i] == ' ') {
      split = i;
      break;
    }
  }
  copy_text_span(primary, primary_size, source, split);
  while (source[split] == ' ') {
    split++;
  }
  copy_bounded_text(secondary, secondary_size, source + split);
}

void draw_top_chrome(GContext *ctx) {
  int width = has_active_route() ? s_screen_bounds.size.w - 8 : 98;
  GRect rect = GRect(4, 4, width, 22);
  draw_card(ctx, rect, chrome_bg(), chrome_border());

  graphics_context_set_fill_color(ctx, chrome_accent());
  graphics_fill_rect(ctx, GRect(rect.origin.x + 4, rect.origin.y + 5, 4, rect.size.h - 10),
                     2, GCornersAll);
  draw_text_in_rect(ctx, GRect(rect.origin.x + 12, rect.origin.y, rect.size.w - 16, rect.size.h),
                    s_top_text, fonts_get_system_font(FONT_KEY_GOTHIC_18_BOLD), chrome_fg(),
                    GTextAlignmentLeft);
}

void draw_compact_status(GContext *ctx) {
  if (s_bottom_text[0] == '\0') {
    return;
  }

  int width = 74;
  if (s_state == AppStateMapLoading || s_state == AppStateWaitingForPhone) {
    width = 112;
  } else if (s_state == AppStateRouteError || s_state == AppStateSetupRequired) {
    width = s_screen_bounds.size.w - 8;
  }
  GRect rect = GRect(4, s_screen_bounds.size.h - 25, width, 21);
  draw_card(ctx, rect, chrome_bg(), chrome_border());
  draw_text_in_rect(ctx, GRect(rect.origin.x + 8, rect.origin.y - 1, rect.size.w - 14, rect.size.h),
                    s_bottom_text, fonts_get_system_font(FONT_KEY_GOTHIC_14_BOLD), chrome_fg(),
                    GTextAlignmentLeft);
}

void draw_route_status(GContext *ctx) {
  char primary[48];
  char secondary[48];
  split_status_text(s_bottom_text, primary, sizeof(primary), secondary, sizeof(secondary));

  GRect rect = GRect(4, s_screen_bounds.size.h - 47, s_screen_bounds.size.w - 8, 43);
  draw_card(ctx, rect, chrome_bg(), chrome_border());
  graphics_context_set_fill_color(ctx, chrome_accent());
  graphics_fill_rect(ctx, GRect(rect.origin.x, rect.origin.y, 4, rect.size.h), 4,
                     GCornerNone);

  draw_text_in_rect(ctx, GRect(rect.origin.x + 10, rect.origin.y + 1, rect.size.w - 16, 21),
                    primary, fonts_get_system_font(FONT_KEY_GOTHIC_18_BOLD), chrome_fg(),
                    GTextAlignmentLeft);
  if (secondary[0] != '\0') {
    draw_text_in_rect(ctx, GRect(rect.origin.x + 10, rect.origin.y + 20, rect.size.w - 16, 19),
                      secondary, fonts_get_system_font(FONT_KEY_GOTHIC_14), chrome_fg(),
                      GTextAlignmentLeft);
  }
}

void draw_status_chrome(GContext *ctx) {
  draw_top_chrome(ctx);
  if (has_active_route()) {
    draw_route_status(ctx);
  } else {
    draw_compact_status(ctx);
  }
}

void draw_arrival_dialog(GContext *ctx) {
  if (!s_arrival_dialog_visible) {
    return;
  }

  int width = s_screen_bounds.size.w - 28;
  if (width > 156) {
    width = 156;
  }
  int height = 76;
  int x = (s_screen_bounds.size.w - width) / 2;
  int y = (s_screen_bounds.size.h - height) / 2;
  GRect rect = GRect(x, y, width, height);
  draw_card(ctx, rect, chrome_bg(), chrome_border());
  graphics_context_set_fill_color(ctx, GColorFromHEX(0x19706D));
  graphics_fill_rect(ctx, GRect(rect.origin.x, rect.origin.y, rect.size.w, 5),
                     0, GCornerNone);
  draw_text_in_rect(ctx, GRect(rect.origin.x + 8, rect.origin.y + 13,
                               rect.size.w - 16, 26),
                    "Arrived", fonts_get_system_font(FONT_KEY_GOTHIC_24_BOLD),
                    chrome_fg(), GTextAlignmentCenter);
  draw_text_in_rect(ctx, GRect(rect.origin.x + 8, rect.origin.y + 42,
                               rect.size.w - 16, 22),
                    "You arrived", fonts_get_system_font(FONT_KEY_GOTHIC_18),
                    chrome_fg(), GTextAlignmentCenter);
}


void draw_menu(GContext *ctx) {
  if (s_menu_mode == MenuNone) {
    return;
  }

  int count = menu_item_count();
  const int max_visible = 5;
  int visible_rows = count < max_visible ? count : max_visible;
  int panel_height = 33 + visible_rows * 22 + 8;
  int panel_y = (s_screen_bounds.size.h - panel_height) / 2;
  if (panel_y < 10) {
    panel_y = 10;
  }

  GRect rect = GRect(6, panel_y, s_screen_bounds.size.w - 12, panel_height);
  draw_card(ctx, rect, GColorFromHEX(0x101719), GColorFromHEX(0x80AFAA));

  GRect header = GRect(rect.origin.x, rect.origin.y, rect.size.w, 25);
  graphics_context_set_fill_color(ctx, GColorFromHEX(0x19706D));
  graphics_fill_rect(ctx, header, 0, GCornerNone);
  graphics_context_set_text_color(ctx, GColorWhite);
  graphics_draw_text(ctx, menu_title(), fonts_get_system_font(FONT_KEY_GOTHIC_18_BOLD),
                     GRect(header.origin.x + 8, header.origin.y + 1, header.size.w - 16, 22),
                     GTextOverflowModeTrailingEllipsis, GTextAlignmentLeft, NULL);

  int first = 0;
  if (s_menu_selection >= max_visible) {
    first = s_menu_selection - max_visible + 1;
  }

  GRect highlight_rect;
  bool has_highlight = menu_highlight_rect(&highlight_rect);
  int highlighted_text_index = has_highlight ?
      menu_highlight_text_index(highlight_rect, first) : s_menu_selection;

  for (int row = 0; row < max_visible && first + row < count; row++) {
    GRect row_rect = GRect(rect.origin.x + 5, rect.origin.y + 31 + row * 22,
                          rect.size.w - 10, 21);
    graphics_context_set_stroke_color(ctx, GColorFromHEX(0x233237));
    graphics_draw_line(ctx, GPoint(row_rect.origin.x + 2, row_rect.origin.y + row_rect.size.h),
                       GPoint(row_rect.origin.x + row_rect.size.w - 2,
                              row_rect.origin.y + row_rect.size.h));
  }

  if (has_highlight) {
    graphics_context_set_fill_color(ctx, GColorWhite);
    graphics_fill_rect(ctx, highlight_rect, 3, GCornersAll);
    GRect accent_rect = GRect(highlight_rect.origin.x + 3,
                              highlight_rect.origin.y + 4,
                              3,
                              highlight_rect.size.h - 8);
    if (accent_rect.size.h > 0) {
      graphics_context_set_fill_color(ctx, GColorFromHEX(0x1A73E8));
      graphics_fill_rect(ctx, accent_rect, 1, GCornersAll);
    }
  }

  for (int row = 0; row < max_visible && first + row < count; row++) {
    int item_index = first + row;
    GRect row_rect = GRect(rect.origin.x + 5, rect.origin.y + 31 + row * 22,
                          rect.size.w - 10, 21);
    char label[48];
    menu_item_label(item_index, label, sizeof(label));
    graphics_context_set_text_color(ctx, item_index == highlighted_text_index ?
                                    GColorFromHEX(0x111719) : GColorWhite);
    graphics_draw_text(ctx, label, fonts_get_system_font(FONT_KEY_GOTHIC_18),
                       GRect(row_rect.origin.x + 10, row_rect.origin.y,
                             row_rect.size.w - 14, row_rect.size.h),
                       GTextOverflowModeTrailingEllipsis, GTextAlignmentLeft, NULL);
  }
}


void map_layer_update(Layer *layer, GContext *ctx) {
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  fixture_perf_map_draw();
#endif
  GColor background = s_theme_mode == 2 ? GColorFromHEX(0x101418) : GColorFromHEX(0xE8EEE8);
  bool fill_background_in_tiles = map_orientation_active();
  if (!fill_background_in_tiles) {
    fill_map_background(ctx, background);
  }

  draw_tile_placeholders(ctx);
  draw_tiles(ctx, background, fill_background_in_tiles);
  MapRenderTransform transform;
  build_map_render_transform(&transform);
  draw_route(ctx, &transform);
  draw_destination_marker(ctx, &transform);
  draw_current_location(ctx, &transform);

  if (s_menu_mode == MenuNone) {
    draw_status_chrome(ctx);
  }
  draw_menu(ctx);
  draw_arrival_dialog(ctx);
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  fixture_perf_map_draw_complete();
  fixture_perf_maybe_emit();
#endif
}
