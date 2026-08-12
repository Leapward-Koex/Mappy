#include <inttypes.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../apps/pebble-watch/src/c/rotated_raster_math.h"
#include "../apps/pebble-watch/src/c/tile_codec.h"

#define TEST_PI 3.14159265358979323846264338327950288
#define MAX_SCREEN_W 200
#define MAX_SCREEN_H 228
#define TEST_ROTATED_RLE_BLOCK_CACHE_SIZE 16

typedef struct {
  int32_t x;
  int32_t y;
} TestCoordinate;

typedef struct {
  int cell_x;
  int cell_y;
  int local_x;
  int local_y;
} TestCursor;

typedef struct {
  uint8_t cell_index;
  uint8_t row;
  uint8_t block;
} TestRleCacheKey;

typedef struct {
  uint64_t samples;
  uint64_t hits;
  uint64_t misses;
  uint64_t decoded_pixels;
  uint64_t invalid_samples;
} TestRleCacheStats;

typedef struct {
  int32_t min_x;
  int32_t min_y;
  int cols;
  int rows;
  int tile_w;
  int tile_h;
} TestRleLookup;

static int s_failures;
static uint64_t s_coordinate_checks;
static uint64_t s_byte_checks;
static uint32_t s_random_state = UINT32_C(0x91e10da5);

#define CHECK(condition, format, ...) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: " format "\n", ##__VA_ARGS__); \
    s_failures++; \
  } \
} while (0)

static uint32_t next_random(void) {
  uint32_t value = s_random_state;
  value ^= value << 13;
  value ^= value >> 17;
  value ^= value << 5;
  s_random_state = value;
  return value;
}

static int32_t reference_round(int32_t numerator) {
  int64_t wide = numerator;
  if (wide >= 0) {
    return (int32_t)((wide + ROTATED_RASTER_TRIG_HALF) /
                     ROTATED_RASTER_TRIG_RATIO);
  }
  return (int32_t)(-((-wide + ROTATED_RASTER_TRIG_HALF) /
                     ROTATED_RASTER_TRIG_RATIO));
}

static int floor_div(int value, int divisor) {
  int quotient = value / divisor;
  int remainder = value % divisor;
  if (remainder < 0) {
    quotient--;
  }
  return quotient;
}

static int32_t scale_world_to_zoom_reference(int32_t value,
                                             int8_t from_zoom,
                                             int8_t to_zoom) {
  if (to_zoom > from_zoom) {
    return value << (to_zoom - from_zoom);
  }
  if (to_zoom < from_zoom) {
    return value >> (from_zoom - to_zoom);
  }
  return value;
}

static int32_t sine_ratio(int degrees) {
  return (int32_t)llround(sin((double)degrees * TEST_PI / 180.0) *
                          ROTATED_RASTER_TRIG_RATIO);
}

static int32_t cosine_ratio(int degrees) {
  return (int32_t)llround(cos((double)degrees * TEST_PI / 180.0) *
                          ROTATED_RASTER_TRIG_RATIO);
}

static void cursor_init(TestCursor *cursor, int32_t world_x, int32_t world_y,
                        int tile_w, int tile_h) {
  cursor->cell_x = floor_div(world_x, tile_w);
  cursor->cell_y = floor_div(world_y, tile_h);
  cursor->local_x = world_x - cursor->cell_x * tile_w;
  cursor->local_y = world_y - cursor->cell_y * tile_h;
}

static void cursor_advance_unit(TestCursor *cursor, int32_t dx, int32_t dy,
                                int tile_w, int tile_h) {
  CHECK(dx >= -1 && dx <= 1 && dy >= -1 && dy <= 1,
        "unit cursor received delta (%" PRId32 ",%" PRId32 ")", dx, dy);
  cursor->local_x += (int)dx;
  if (cursor->local_x < 0) {
    cursor->local_x += tile_w;
    cursor->cell_x--;
  } else if (cursor->local_x >= tile_w) {
    cursor->local_x -= tile_w;
    cursor->cell_x++;
  }
  cursor->local_y += (int)dy;
  if (cursor->local_y < 0) {
    cursor->local_y += tile_h;
    cursor->cell_y--;
  } else if (cursor->local_y >= tile_h) {
    cursor->local_y -= tile_h;
    cursor->cell_y++;
  }
  CHECK(cursor->local_x >= 0 && cursor->local_x < tile_w &&
        cursor->local_y >= 0 && cursor->local_y < tile_h,
        "cursor lost normalization");
}

static int32_t cursor_world_x(const TestCursor *cursor, int tile_w) {
  return cursor->cell_x * tile_w + cursor->local_x;
}

static int32_t cursor_world_y(const TestCursor *cursor, int tile_h) {
  return cursor->cell_y * tile_h + cursor->local_y;
}

static void reference_coordinates(TestCoordinate *coordinates,
                                  int width, int height,
                                  int center_x, int center_y,
                                  int32_t viewport_x, int32_t viewport_y,
                                  int32_t sin_value, int32_t cos_value) {
  for (int y = 0; y < height; y++) {
    int32_t sy = y - center_y;
    for (int x = 0; x < width; x++) {
      int32_t sx = x - center_x;
      int32_t x_numerator = sx * cos_value - sy * sin_value;
      int32_t y_numerator = sx * sin_value + sy * cos_value;
      coordinates[y * width + x] = (TestCoordinate) {
        .x = viewport_x + reference_round(x_numerator),
        .y = viewport_y + reference_round(y_numerator),
      };
    }
  }
}

static int bearing_independent_radius(int width, int height) {
  int32_t half_w = (width + 1) / 2;
  int32_t half_h = (height + 1) / 2;
  uint64_t radius_sq = (uint64_t)half_w * (uint64_t)half_w +
      (uint64_t)half_h * (uint64_t)half_h;
  int32_t low = 0;
  int32_t high = half_w + half_h;
  while (low < high) {
    int32_t mid = low + (high - low) / 2;
    if ((uint64_t)mid * (uint64_t)mid >= radius_sq) {
      high = mid;
    } else {
      low = mid + 1;
    }
  }
  return low;
}

static TestRleLookup make_rle_lookup(int width, int height,
                                     int tile_w, int tile_h,
                                     int32_t viewport_x,
                                     int32_t viewport_y) {
  int radius = bearing_independent_radius(width, height);
  int32_t min_x = floor_div(viewport_x - radius, tile_w) * tile_w;
  int32_t max_x = floor_div(viewport_x + radius, tile_w) * tile_w;
  int32_t min_y = floor_div(viewport_y - radius, tile_h) * tile_h;
  int32_t max_y = floor_div(viewport_y + radius, tile_h) * tile_h;
  return (TestRleLookup) {
    .min_x = min_x,
    .min_y = min_y,
    .cols = (int)((max_x - min_x) / tile_w) + 1,
    .rows = (int)((max_y - min_y) / tile_h) + 1,
    .tile_w = tile_w,
    .tile_h = tile_h,
  };
}

static bool sample_test_rle_cache(
    const TestRleLookup *lookup, const TestCoordinate *coordinate,
    TestRleCacheKey cache[TEST_ROTATED_RLE_BLOCK_CACHE_SIZE],
    TestRleCacheStats *stats) {
  stats->samples++;
  int32_t dx = coordinate->x - lookup->min_x;
  int32_t dy = coordinate->y - lookup->min_y;
  int col = floor_div(dx, lookup->tile_w);
  int row = floor_div(dy, lookup->tile_h);
  int local_x = (int)(dx - (int32_t)col * lookup->tile_w);
  int local_y = (int)(dy - (int32_t)row * lookup->tile_h);
  if (col < 0 || col >= lookup->cols || row < 0 || row >= lookup->rows ||
      local_x < 0 || local_x >= lookup->tile_w ||
      local_y < 0 || local_y >= lookup->tile_h) {
    stats->invalid_samples++;
    return false;
  }

  int cell = row * lookup->cols + col;
  int block_value = local_x / TILE_RLE_INDEX_BLOCK_PIXELS;
  if (cell < 0 || cell >= UINT8_MAX || block_value < 0 ||
      block_value >= UINT8_MAX || local_y >= UINT8_MAX) {
    stats->invalid_samples++;
    return false;
  }
  uint8_t cell_index = (uint8_t)cell;
  uint8_t block = (uint8_t)block_value;

  // Keep this hash and key comparison byte-for-byte equivalent to the
  // production 16-slot direct-mapped rotated RLE block cache.
  uint8_t slot = (uint8_t)(((cell_index * 7) +
                            (uint16_t)local_y * 5 + block * 11) &
                           (TEST_ROTATED_RLE_BLOCK_CACHE_SIZE - 1));
  TestRleCacheKey *cached = &cache[slot];
  if (cached->cell_index == cell_index &&
      cached->row == (uint8_t)local_y && cached->block == block) {
    stats->hits++;
    return true;
  }

  stats->misses++;
  int decoded_pixels = lookup->tile_w -
      block_value * TILE_RLE_INDEX_BLOCK_PIXELS;
  if (decoded_pixels > TILE_RLE_INDEX_BLOCK_PIXELS) {
    decoded_pixels = TILE_RLE_INDEX_BLOCK_PIXELS;
  }
  stats->decoded_pixels += (uint64_t)decoded_pixels;
  cached->cell_index = cell_index;
  cached->row = (uint8_t)local_y;
  cached->block = block;
  return true;
}

static TestRleCacheStats simulate_rle_cache_order(
    const TestCoordinate *coordinates, int width, int height,
    const TestRleLookup *lookup, bool block_order) {
  TestRleCacheStats stats = {0};
  TestRleCacheKey cache[TEST_ROTATED_RLE_BLOCK_CACHE_SIZE];
  memset(cache, 0xff, sizeof(cache));

  if (!block_order) {
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        sample_test_rle_cache(lookup, &coordinates[y * width + x],
                              cache, &stats);
      }
    }
    return stats;
  }

  for (int block_y = 0; block_y < height;
       block_y += ROTATED_RASTER_BLOCK_SIZE) {
    int block_h = height - block_y;
    if (block_h > ROTATED_RASTER_BLOCK_SIZE) {
      block_h = ROTATED_RASTER_BLOCK_SIZE;
    }
    for (int block_x = 0; block_x < width;
         block_x += ROTATED_RASTER_BLOCK_SIZE) {
      int block_w = width - block_x;
      if (block_w > ROTATED_RASTER_BLOCK_SIZE) {
        block_w = ROTATED_RASTER_BLOCK_SIZE;
      }
      for (int block_row = 0; block_row < block_h; block_row++) {
        for (int block_col = 0; block_col < block_w; block_col++) {
          int x = block_x + block_col;
          int y = block_y + block_row;
          sample_test_rle_cache(lookup, &coordinates[y * width + x],
                                cache, &stats);
        }
      }
    }
  }
  return stats;
}

static void dda_coordinates(TestCoordinate *coordinates,
                            int width, int height,
                            int center_x, int center_y,
                            int32_t viewport_x, int32_t viewport_y,
                            int32_t sin_value, int32_t cos_value) {
  RotatedRasterDda dda;
  rotated_raster_dda_init(&dda, center_x, center_y, sin_value, cos_value);
  RotatedRasterPoint next_row = dda.row_origin;
  TestCoordinate next_row_coordinate = {
    .x = viewport_x + next_row.x.rounded,
    .y = viewport_y + next_row.y.rounded,
  };

  for (int block_y = 0; block_y < height;
       block_y += ROTATED_RASTER_BLOCK_SIZE) {
    int block_h = height - block_y;
    if (block_h > ROTATED_RASTER_BLOCK_SIZE) {
      block_h = ROTATED_RASTER_BLOCK_SIZE;
    }
    RotatedRasterPoint row_points[ROTATED_RASTER_BLOCK_SIZE];
    TestCoordinate row_coordinates[ROTATED_RASTER_BLOCK_SIZE];
    for (int block_row = 0; block_row < block_h; block_row++) {
      row_points[block_row] = next_row;
      row_coordinates[block_row] = next_row_coordinate;
      if (block_y + block_row + 1 < height) {
        int32_t dx;
        int32_t dy;
        rotated_raster_point_advance(&next_row, &dda.row_x, &dda.row_y,
                                     &dx, &dy);
        next_row_coordinate.x += dx;
        next_row_coordinate.y += dy;
      }
    }
    for (int block_x = 0; block_x < width;
         block_x += ROTATED_RASTER_BLOCK_SIZE) {
      int block_w = width - block_x;
      if (block_w > ROTATED_RASTER_BLOCK_SIZE) {
        block_w = ROTATED_RASTER_BLOCK_SIZE;
      }
      for (int block_row = 0; block_row < block_h; block_row++) {
        for (int block_col = 0; block_col < block_w; block_col++) {
          int x = block_x + block_col;
          coordinates[(block_y + block_row) * width + x] =
              row_coordinates[block_row];
          if (x + 1 < width) {
            int32_t dx;
            int32_t dy;
            rotated_raster_point_advance(&row_points[block_row],
                                         &dda.pixel_x, &dda.pixel_y,
                                         &dx, &dy);
            row_coordinates[block_row].x += dx;
            row_coordinates[block_row].y += dy;
          }
        }
      }
    }
  }
}

static void cardinal_coordinates(TestCoordinate *coordinates,
                                 int width, int height,
                                 int center_x, int center_y,
                                 int32_t viewport_x, int32_t viewport_y,
                                 const RotatedRasterCardinal *cardinal) {
  int32_t top_left_x;
  int32_t top_left_y;
  rotated_raster_cardinal_top_left(cardinal, center_x, center_y,
                                   &top_left_x, &top_left_y);
  TestCoordinate next_row = {
    .x = viewport_x + top_left_x,
    .y = viewport_y + top_left_y,
  };
  for (int block_y = 0; block_y < height;
       block_y += ROTATED_RASTER_BLOCK_SIZE) {
    int block_h = height - block_y;
    if (block_h > ROTATED_RASTER_BLOCK_SIZE) {
      block_h = ROTATED_RASTER_BLOCK_SIZE;
    }
    TestCoordinate rows[ROTATED_RASTER_BLOCK_SIZE];
    for (int block_row = 0; block_row < block_h; block_row++) {
      rows[block_row] = next_row;
      if (block_y + block_row + 1 < height) {
        next_row.x += cardinal->row_dx;
        next_row.y += cardinal->row_dy;
      }
    }
    for (int block_x = 0; block_x < width;
         block_x += ROTATED_RASTER_BLOCK_SIZE) {
      int block_w = width - block_x;
      if (block_w > ROTATED_RASTER_BLOCK_SIZE) {
        block_w = ROTATED_RASTER_BLOCK_SIZE;
      }
      for (int block_row = 0; block_row < block_h; block_row++) {
        for (int block_col = 0; block_col < block_w; block_col++) {
          int x = block_x + block_col;
          coordinates[(block_y + block_row) * width + x] = rows[block_row];
          if (x + 1 < width) {
            rows[block_row].x += cardinal->pixel_dx;
            rows[block_row].y += cardinal->pixel_dy;
          }
        }
      }
    }
  }
}

static void optimized_coordinates(TestCoordinate *coordinates,
                                  int width, int height,
                                  int center_x, int center_y,
                                  int32_t viewport_x, int32_t viewport_y,
                                  int32_t sin_value, int32_t cos_value) {
  RotatedRasterCardinal cardinal;
  if (rotated_raster_cardinal_init(&cardinal, sin_value, cos_value)) {
    cardinal_coordinates(coordinates, width, height, center_x, center_y,
                         viewport_x, viewport_y, &cardinal);
  } else {
    dda_coordinates(coordinates, width, height, center_x, center_y,
                    viewport_x, viewport_y, sin_value, cos_value);
  }
}

static void compare_coordinate_case(TestCoordinate *reference,
                                    TestCoordinate *optimized,
                                    int width, int height,
                                    int32_t viewport_x, int32_t viewport_y,
                                    int32_t sin_value, int32_t cos_value,
                                    const char *label) {
  int center_x = width / 2;
  int center_y = height / 2;
  reference_coordinates(reference, width, height, center_x, center_y,
                        viewport_x, viewport_y, sin_value, cos_value);
  optimized_coordinates(optimized, width, height, center_x, center_y,
                        viewport_x, viewport_y, sin_value, cos_value);
  size_t count = (size_t)width * height;
  for (size_t i = 0; i < count; i++) {
    s_coordinate_checks++;
    if (reference[i].x != optimized[i].x ||
        reference[i].y != optimized[i].y) {
      CHECK(false,
            "%s coordinate %zu expected (%" PRId32 ",%" PRId32
            ") got (%" PRId32 ",%" PRId32 ")",
            label, i, reference[i].x, reference[i].y,
            optimized[i].x, optimized[i].y);
      return;
    }
  }
}

static bool synthetic_sample_world(int32_t world_x, int32_t world_y,
                                   int tile_w, int tile_h,
                                   uint8_t *value) {
  int cell_x = floor_div(world_x, tile_w);
  int cell_y = floor_div(world_y, tile_h);
  int local_x = world_x - cell_x * tile_w;
  int local_y = world_y - cell_y * tile_h;
  uint32_t tile_hash = (uint32_t)cell_x * UINT32_C(0x9e3779b1) ^
      (uint32_t)cell_y * UINT32_C(0x85ebca6b);
  if ((tile_hash & 7) == 3) {
    return false;
  }
  // Include a deterministic animation-like mask so traversal order cannot
  // hide differences in local tile coordinates.
  if (((local_x & 7) * 5 + (local_y & 7) * 3 + (tile_hash >> 8)) % 29 == 0) {
    return false;
  }
  *value = (uint8_t)(1 + ((tile_hash + (uint32_t)local_x * 17 +
                           (uint32_t)local_y * 31) % 254));
  return true;
}

static bool synthetic_sample_cursor(const TestCursor *cursor,
                                    int tile_w, int tile_h,
                                    uint8_t *value) {
  return synthetic_sample_world(cursor_world_x(cursor, tile_w),
                                cursor_world_y(cursor, tile_h),
                                tile_w, tile_h, value);
}

static void render_reference(uint8_t *framebuffer, int stride,
                             int width, int height,
                             int32_t viewport_x, int32_t viewport_y,
                             int8_t viewport_zoom, int8_t sample_zoom,
                             int32_t sin_value, int32_t cos_value,
                             int tile_w, int tile_h,
                             bool fill_missing, uint8_t background) {
  int center_x = width / 2;
  int center_y = height / 2;
  for (int y = 0; y < height; y++) {
    int32_t sy = y - center_y;
    for (int x = 0; x < width; x++) {
      int32_t sx = x - center_x;
      int32_t world_x = viewport_x +
          reference_round(sx * cos_value - sy * sin_value);
      int32_t world_y = viewport_y +
          reference_round(sx * sin_value + sy * cos_value);
      int32_t sample_x = scale_world_to_zoom_reference(
          world_x, viewport_zoom, sample_zoom);
      int32_t sample_y = scale_world_to_zoom_reference(
          world_y, viewport_zoom, sample_zoom);
      uint8_t value;
      if (synthetic_sample_world(sample_x, sample_y, tile_w, tile_h, &value)) {
        framebuffer[y * stride + x] = value;
      } else if (fill_missing) {
        framebuffer[y * stride + x] = background;
      }
    }
  }
}

static void render_optimized_dda(uint8_t *framebuffer, int stride,
                                 int width, int height,
                                 int32_t viewport_x, int32_t viewport_y,
                                 int32_t sin_value, int32_t cos_value,
                                 int tile_w, int tile_h,
                                 bool fill_missing, uint8_t background) {
  RotatedRasterDda dda;
  rotated_raster_dda_init(&dda, width / 2, height / 2,
                          sin_value, cos_value);
  RotatedRasterPoint next_row_point = dda.row_origin;
  TestCursor next_row_cursor;
  cursor_init(&next_row_cursor,
              viewport_x + next_row_point.x.rounded,
              viewport_y + next_row_point.y.rounded,
              tile_w, tile_h);

  for (int block_y = 0; block_y < height;
       block_y += ROTATED_RASTER_BLOCK_SIZE) {
    int block_h = height - block_y;
    if (block_h > ROTATED_RASTER_BLOCK_SIZE) {
      block_h = ROTATED_RASTER_BLOCK_SIZE;
    }
    RotatedRasterPoint row_points[ROTATED_RASTER_BLOCK_SIZE];
    TestCursor row_cursors[ROTATED_RASTER_BLOCK_SIZE];
    for (int row = 0; row < block_h; row++) {
      row_points[row] = next_row_point;
      row_cursors[row] = next_row_cursor;
      if (block_y + row + 1 < height) {
        int32_t dx;
        int32_t dy;
        rotated_raster_point_advance(&next_row_point,
                                     &dda.row_x, &dda.row_y, &dx, &dy);
        cursor_advance_unit(&next_row_cursor, dx, dy, tile_w, tile_h);
      }
    }
    for (int block_x = 0; block_x < width;
         block_x += ROTATED_RASTER_BLOCK_SIZE) {
      int block_w = width - block_x;
      if (block_w > ROTATED_RASTER_BLOCK_SIZE) {
        block_w = ROTATED_RASTER_BLOCK_SIZE;
      }
      for (int row = 0; row < block_h; row++) {
        for (int col = 0; col < block_w; col++) {
          int x = block_x + col;
          uint8_t value;
          if (synthetic_sample_cursor(&row_cursors[row], tile_w, tile_h,
                                      &value)) {
            framebuffer[(block_y + row) * stride + x] = value;
          } else if (fill_missing) {
            framebuffer[(block_y + row) * stride + x] = background;
          }
          if (x + 1 < width) {
            int32_t dx;
            int32_t dy;
            rotated_raster_point_advance(&row_points[row],
                                         &dda.pixel_x, &dda.pixel_y,
                                         &dx, &dy);
            cursor_advance_unit(&row_cursors[row], dx, dy, tile_w, tile_h);
          }
        }
      }
    }
  }
}

static void render_optimized_cardinal(
    uint8_t *framebuffer, int stride, int width, int height,
    int32_t viewport_x, int32_t viewport_y,
    const RotatedRasterCardinal *cardinal,
    int tile_w, int tile_h, bool fill_missing, uint8_t background) {
  int32_t top_left_x;
  int32_t top_left_y;
  rotated_raster_cardinal_top_left(cardinal, width / 2, height / 2,
                                   &top_left_x, &top_left_y);
  TestCursor next_row_cursor;
  cursor_init(&next_row_cursor, viewport_x + top_left_x,
              viewport_y + top_left_y, tile_w, tile_h);
  for (int block_y = 0; block_y < height;
       block_y += ROTATED_RASTER_BLOCK_SIZE) {
    int block_h = height - block_y;
    if (block_h > ROTATED_RASTER_BLOCK_SIZE) {
      block_h = ROTATED_RASTER_BLOCK_SIZE;
    }
    TestCursor rows[ROTATED_RASTER_BLOCK_SIZE];
    for (int row = 0; row < block_h; row++) {
      rows[row] = next_row_cursor;
      if (block_y + row + 1 < height) {
        cursor_advance_unit(&next_row_cursor,
                            cardinal->row_dx, cardinal->row_dy,
                            tile_w, tile_h);
      }
    }
    for (int block_x = 0; block_x < width;
         block_x += ROTATED_RASTER_BLOCK_SIZE) {
      int block_w = width - block_x;
      if (block_w > ROTATED_RASTER_BLOCK_SIZE) {
        block_w = ROTATED_RASTER_BLOCK_SIZE;
      }
      for (int row = 0; row < block_h; row++) {
        for (int col = 0; col < block_w; col++) {
          int x = block_x + col;
          uint8_t value;
          if (synthetic_sample_cursor(&rows[row], tile_w, tile_h, &value)) {
            framebuffer[(block_y + row) * stride + x] = value;
          } else if (fill_missing) {
            framebuffer[(block_y + row) * stride + x] = background;
          }
          if (x + 1 < width) {
            cursor_advance_unit(&rows[row],
                                cardinal->pixel_dx, cardinal->pixel_dy,
                                tile_w, tile_h);
          }
        }
      }
    }
  }
}

static void render_optimized_current_zoom(
    uint8_t *framebuffer, int stride, int width, int height,
    int32_t viewport_x, int32_t viewport_y,
    int32_t sin_value, int32_t cos_value,
    int tile_w, int tile_h, bool fill_missing, uint8_t background) {
  RotatedRasterCardinal cardinal;
  if (rotated_raster_cardinal_init(&cardinal, sin_value, cos_value)) {
    render_optimized_cardinal(framebuffer, stride, width, height,
                              viewport_x, viewport_y, &cardinal,
                              tile_w, tile_h, fill_missing, background);
  } else {
    render_optimized_dda(framebuffer, stride, width, height,
                         viewport_x, viewport_y, sin_value, cos_value,
                         tile_w, tile_h, fill_missing, background);
  }
}

static void assert_framebuffers_equal(const uint8_t *reference,
                                      const uint8_t *optimized,
                                      size_t size, const char *label) {
  for (size_t i = 0; i < size; i++) {
    s_byte_checks++;
    if (reference[i] != optimized[i]) {
      CHECK(false, "%s byte %zu expected %u got %u", label, i,
            (unsigned)reference[i], (unsigned)optimized[i]);
      return;
    }
  }
}

static void fill_seed(uint8_t *bytes, size_t size, uint32_t seed) {
  uint32_t value = seed;
  for (size_t i = 0; i < size; i++) {
    value = value * UINT32_C(1664525) + UINT32_C(1013904223);
    bytes[i] = (uint8_t)(value >> 24);
  }
}

static void test_rounding_boundaries(void) {
  for (int multiple = -220; multiple <= 220; multiple++) {
    for (int offset = -ROTATED_RASTER_TRIG_HALF - 2;
         offset <= ROTATED_RASTER_TRIG_HALF + 2; offset++) {
      int32_t numerator = multiple * ROTATED_RASTER_TRIG_RATIO + offset;
      CHECK(rotated_raster_round_nearest(numerator) ==
                reference_round(numerator),
            "rounding mismatch numerator=%" PRId32, numerator);
    }
  }
}

static void test_step_decomposition_and_sequences(void) {
  const int32_t seeds[] = {
    -13000000, -65536, -65535, -32768, -32767,
    -1, 0, 1, 32767, 32768, 65535, 65536, 13000000,
  };
  for (int32_t delta = -ROTATED_RASTER_TRIG_RATIO;
       delta <= ROTATED_RASTER_TRIG_RATIO; delta++) {
    RotatedRasterStep step;
    rotated_raster_step_init(&step, delta);
    CHECK(step.phase < ROTATED_RASTER_TRIG_RATIO,
          "step phase out of range delta=%" PRId32, delta);
    CHECK((int32_t)step.whole * ROTATED_RASTER_TRIG_RATIO + step.phase ==
              delta,
          "step reconstruction failed delta=%" PRId32, delta);
    for (size_t i = 0; i < sizeof(seeds) / sizeof(seeds[0]); i++) {
      RotatedRasterAccumulator accumulator;
      rotated_raster_accumulator_init(&accumulator, seeds[i]);
      int32_t actual_delta = rotated_raster_accumulator_advance(
          &accumulator, &step);
      int32_t expected = reference_round(seeds[i] + delta);
      CHECK(accumulator.rounded == expected,
            "single advance failed seed=%" PRId32 " delta=%" PRId32,
            seeds[i], delta);
      CHECK(actual_delta == expected - reference_round(seeds[i]),
            "advance delta failed seed=%" PRId32 " delta=%" PRId32,
            seeds[i], delta);
      CHECK(accumulator.phase < ROTATED_RASTER_TRIG_RATIO,
            "advance phase out of range");
    }
  }

  for (int sequence = 0; sequence < 512; sequence++) {
    int32_t numerator = (int32_t)(next_random() % UINT32_C(20000001)) -
        INT32_C(10000000);
    RotatedRasterAccumulator accumulator;
    rotated_raster_accumulator_init(&accumulator, numerator);
    for (int i = 0; i < 1024; i++) {
      int32_t delta = (int32_t)(next_random() %
          (UINT32_C(2) * ROTATED_RASTER_TRIG_RATIO + 1)) -
          ROTATED_RASTER_TRIG_RATIO;
      RotatedRasterStep step;
      rotated_raster_step_init(&step, delta);
      numerator += delta;
      rotated_raster_accumulator_advance(&accumulator, &step);
      CHECK(accumulator.rounded == reference_round(numerator),
            "sequence=%d step=%d numerator=%" PRId32,
            sequence, i, numerator);
      CHECK(accumulator.phase < ROTATED_RASTER_TRIG_RATIO,
            "sequence phase out of range");
    }
  }
}

static void test_cardinals(void) {
  const int32_t pairs[4][2] = {
    {0, ROTATED_RASTER_TRIG_RATIO},
    {ROTATED_RASTER_TRIG_RATIO, 0},
    {0, -ROTATED_RASTER_TRIG_RATIO},
    {-ROTATED_RASTER_TRIG_RATIO, 0},
  };
  for (int i = 0; i < 4; i++) {
    RotatedRasterCardinal cardinal;
    CHECK(rotated_raster_cardinal_init(&cardinal, pairs[i][0], pairs[i][1]),
          "cardinal %d was not recognized", i);
  }
  RotatedRasterCardinal cardinal;
  CHECK(!rotated_raster_cardinal_init(
            &cardinal, 1, ROTATED_RASTER_TRIG_RATIO - 1),
        "near north must not snap to cardinal");
  CHECK(!rotated_raster_cardinal_init(
            &cardinal, ROTATED_RASTER_TRIG_RATIO - 1, 1),
        "near east must not snap to cardinal");
}

static void test_exact_raster_bounds(void) {
  const int width = 200;
  const int height = 228;
  const int center_x = width / 2;
  const int center_y = height / 2;
  for (int degrees = 0; degrees < 360; degrees++) {
    int32_t sin_value = sine_ratio(degrees);
    int32_t cos_value = cosine_ratio(degrees);
    RotatedRasterBounds bounds;
    rotated_raster_bounds_init(&bounds, width, height, center_x, center_y,
                               sin_value, cos_value);
    int32_t min_x = INT32_MAX;
    int32_t max_x = INT32_MIN;
    int32_t min_y = INT32_MAX;
    int32_t max_y = INT32_MIN;
    for (int y = 0; y < height; y++) {
      int32_t sy = y - center_y;
      for (int x = 0; x < width; x++) {
        int32_t sx = x - center_x;
        int32_t world_x = reference_round(
            sx * cos_value - sy * sin_value);
        int32_t world_y = reference_round(
            sx * sin_value + sy * cos_value);
        if (world_x < min_x) min_x = world_x;
        if (world_x > max_x) max_x = world_x;
        if (world_y < min_y) min_y = world_y;
        if (world_y > max_y) max_y = world_y;
      }
    }
    CHECK(bounds.min_x == min_x && bounds.max_x == max_x &&
              bounds.min_y == min_y && bounds.max_y == max_y,
          "angle %d raster bounds mismatch", degrees);
  }
}

static void test_coordinate_equivalence(void) {
  size_t capacity = (size_t)MAX_SCREEN_W * MAX_SCREEN_H;
  TestCoordinate *reference = malloc(capacity * sizeof(*reference));
  TestCoordinate *optimized = malloc(capacity * sizeof(*optimized));
  CHECK(reference && optimized, "coordinate buffers must allocate");
  if (!reference || !optimized) {
    free(reference);
    free(optimized);
    return;
  }

  char label[80];
  for (int degrees = 0; degrees < 360; degrees++) {
    int32_t viewport_x = (degrees & 1) ? INT32_C(8388608) : -INT32_C(8388608);
    int32_t viewport_y = (degrees & 2) ? INT32_C(4194304) : -INT32_C(4194304);
    snprintf(label, sizeof(label), "angle %d", degrees);
    compare_coordinate_case(reference, optimized, 200, 228,
                            viewport_x, viewport_y,
                            sine_ratio(degrees), cosine_ratio(degrees), label);
  }

  const int sizes[][2] = {
    {1, 1}, {7, 9}, {8, 8}, {9, 7}, {17, 19}, {199, 227}, {200, 228},
  };
  for (size_t size = 0; size < sizeof(sizes) / sizeof(sizes[0]); size++) {
    for (int case_index = 0; case_index < 32; case_index++) {
      int32_t sin_value = (int32_t)(next_random() % UINT32_C(131071)) -
          ROTATED_RASTER_TRIG_RATIO;
      int32_t cos_value = (int32_t)(next_random() % UINT32_C(131071)) -
          ROTATED_RASTER_TRIG_RATIO;
      snprintf(label, sizeof(label), "random size %dx%d case %d",
               sizes[size][0], sizes[size][1], case_index);
      compare_coordinate_case(reference, optimized,
                              sizes[size][0], sizes[size][1],
                              (int32_t)next_random() / 256,
                              (int32_t)next_random() / 256,
                              sin_value, cos_value, label);
    }
  }
  free(reference);
  free(optimized);
}

static void test_cursor_equivalence(void) {
  const int geometries[][2] = {{54, 63}, {72, 84}, {108, 126}};
  for (size_t geometry = 0;
       geometry < sizeof(geometries) / sizeof(geometries[0]); geometry++) {
    int tile_w = geometries[geometry][0];
    int tile_h = geometries[geometry][1];
    for (int sequence = 0; sequence < 256; sequence++) {
      int32_t world_x = (int32_t)(next_random() % UINT32_C(2000001)) - 1000000;
      int32_t world_y = (int32_t)(next_random() % UINT32_C(2000001)) - 1000000;
      TestCursor cursor;
      cursor_init(&cursor, world_x, world_y, tile_w, tile_h);
      for (int step = 0; step < 2048; step++) {
        int32_t dx = (int32_t)(next_random() % 3) - 1;
        int32_t dy = (int32_t)(next_random() % 3) - 1;
        world_x += dx;
        world_y += dy;
        cursor_advance_unit(&cursor, dx, dy, tile_w, tile_h);
        CHECK(cursor_world_x(&cursor, tile_w) == world_x &&
              cursor_world_y(&cursor, tile_h) == world_y,
              "cursor mismatch geometry=%dx%d sequence=%d step=%d",
              tile_w, tile_h, sequence, step);
      }
    }
  }
}

static void test_rle_cache_locality(void) {
  const int width = 200;
  const int height = 228;
  const int tile_w = 54;
  const int tile_h = 63;
  const int32_t viewport_x = INT32_C(8388608);
  const int32_t viewport_y = INT32_C(4194304);
  const int bearings[] = {4, 30, 45, 75, 90};
  size_t coordinate_count = (size_t)width * height;
  TestCoordinate *coordinates = malloc(coordinate_count * sizeof(*coordinates));
  CHECK(coordinates != NULL, "RLE locality coordinates must allocate");
  if (!coordinates) {
    return;
  }

  // This is the 42-cell, bearing-independent request grid used by a
  // 200x228 face-forward viewport with 54x63 tiles. Every cell is modeled as
  // valid indexed RLE so the comparison isolates traversal/cache locality.
  TestRleLookup lookup = make_rle_lookup(width, height, tile_w, tile_h,
                                         viewport_x, viewport_y);
  CHECK(lookup.cols == 7 && lookup.rows == 6,
        "RLE locality lookup expected 7x6, got %dx%d",
        lookup.cols, lookup.rows);

  TestRleCacheStats legacy_total = {0};
  TestRleCacheStats blocked_total = {0};
  for (size_t i = 0; i < sizeof(bearings) / sizeof(bearings[0]); i++) {
    int degrees = bearings[i];
    reference_coordinates(coordinates, width, height, width / 2, height / 2,
                          viewport_x, viewport_y,
                          sine_ratio(degrees), cosine_ratio(degrees));

    // Feed the same precomputed, pixel-exact source coordinates to both
    // simulations. Only the access order differs: legacy scanlines versus
    // the production persistent-row 8x8 traversal.
    TestRleCacheStats legacy = simulate_rle_cache_order(
        coordinates, width, height, &lookup, false);
    TestRleCacheStats blocked = simulate_rle_cache_order(
        coordinates, width, height, &lookup, true);
    uint64_t expected_samples = (uint64_t)width * (uint64_t)height;

    CHECK(legacy.samples == expected_samples &&
              blocked.samples == expected_samples,
          "RLE locality angle %d sample count mismatch", degrees);
    CHECK(legacy.invalid_samples == 0 && blocked.invalid_samples == 0,
          "RLE locality angle %d sampled outside all-RLE lookup "
          "(legacy=%" PRIu64 ", 8x8=%" PRIu64 ")",
          degrees, legacy.invalid_samples, blocked.invalid_samples);
    CHECK(legacy.hits + legacy.misses == expected_samples &&
              blocked.hits + blocked.misses == expected_samples,
          "RLE locality angle %d hit/miss accounting mismatch", degrees);

    // Require at least a 40%% miss-ratio and decoded-pixel reduction for
    // every representative angle. The deterministic aggregate is stronger,
    // but this per-bearing floor protects the shallow 4-degree case too.
    CHECK(blocked.misses * UINT64_C(100) <=
              legacy.misses * UINT64_C(60),
          "RLE locality angle %d miss ratio regressed "
          "(legacy=%" PRIu64 ", 8x8=%" PRIu64 ")",
          degrees, legacy.misses, blocked.misses);
    CHECK(blocked.decoded_pixels * UINT64_C(100) <=
              legacy.decoded_pixels * UINT64_C(60),
          "RLE locality angle %d decoded pixels regressed "
          "(legacy=%" PRIu64 ", 8x8=%" PRIu64 ")",
          degrees, legacy.decoded_pixels, blocked.decoded_pixels);

    printf("RLE locality angle=%d "
           "legacy_misses=%" PRIu64 " legacy_hits=%" PRIu64
           " legacy_decoded=%" PRIu64 " "
           "8x8_misses=%" PRIu64 " 8x8_hits=%" PRIu64
           " 8x8_decoded=%" PRIu64 "\n",
           degrees, legacy.misses, legacy.hits, legacy.decoded_pixels,
           blocked.misses, blocked.hits, blocked.decoded_pixels);

    legacy_total.samples += legacy.samples;
    legacy_total.hits += legacy.hits;
    legacy_total.misses += legacy.misses;
    legacy_total.decoded_pixels += legacy.decoded_pixels;
    legacy_total.invalid_samples += legacy.invalid_samples;
    blocked_total.samples += blocked.samples;
    blocked_total.hits += blocked.hits;
    blocked_total.misses += blocked.misses;
    blocked_total.decoded_pixels += blocked.decoded_pixels;
    blocked_total.invalid_samples += blocked.invalid_samples;
  }

  // Across the full bearing set, retain at least a 65%% reduction. This is
  // intentionally below the deterministic result to leave room for benign
  // coordinate/test-set expansion without weakening the locality guarantee.
  CHECK(blocked_total.misses * UINT64_C(100) <=
            legacy_total.misses * UINT64_C(35),
        "aggregate RLE miss ratio must improve by at least 65%% "
        "(legacy=%" PRIu64 ", 8x8=%" PRIu64 ")",
        legacy_total.misses, blocked_total.misses);
  CHECK(blocked_total.decoded_pixels * UINT64_C(100) <=
            legacy_total.decoded_pixels * UINT64_C(35),
        "aggregate RLE decoded pixels must improve by at least 65%% "
        "(legacy=%" PRIu64 ", 8x8=%" PRIu64 ")",
        legacy_total.decoded_pixels, blocked_total.decoded_pixels);
  printf("RLE locality aggregate "
         "legacy_misses=%" PRIu64 " legacy_decoded=%" PRIu64 " "
         "8x8_misses=%" PRIu64 " 8x8_decoded=%" PRIu64 "\n",
         legacy_total.misses, legacy_total.decoded_pixels,
         blocked_total.misses, blocked_total.decoded_pixels);
  free(coordinates);
}

static void test_framebuffer_equivalence(void) {
  const int geometries[][2] = {{54, 63}, {72, 84}, {108, 126}};
  const int bearings[] = {0, 1, 4, 37, 89, 90, 179, 180, 269, 270, 359};
  const int sizes[][2] = {{7, 9}, {17, 19}, {199, 227}, {200, 228}};
  const int stride = MAX_SCREEN_W + 7;
  size_t buffer_size = (size_t)stride * MAX_SCREEN_H;
  uint8_t *reference = malloc(buffer_size);
  uint8_t *optimized = malloc(buffer_size);
  CHECK(reference && optimized, "framebuffers must allocate");
  if (!reference || !optimized) {
    free(reference);
    free(optimized);
    return;
  }

  char label[128];
  for (size_t geometry = 0;
       geometry < sizeof(geometries) / sizeof(geometries[0]); geometry++) {
    for (size_t size = 0; size < sizeof(sizes) / sizeof(sizes[0]); size++) {
      int width = sizes[size][0];
      int height = sizes[size][1];
      size_t active_size = (size_t)stride * height;
      for (size_t bearing = 0;
           bearing < sizeof(bearings) / sizeof(bearings[0]); bearing++) {
        int32_t sin_value = sine_ratio(bearings[bearing]);
        int32_t cos_value = cosine_ratio(bearings[bearing]);
        for (int fill = 0; fill <= 1; fill++) {
          uint32_t seed = (uint32_t)(geometry * 10000 + size * 1000 +
                                     bearing * 10 + fill);
          fill_seed(reference, active_size, seed);
          memcpy(optimized, reference, active_size);
          int32_t viewport_x = (bearing & 1) ? INT32_C(8388608) :
              -INT32_C(8388608);
          int32_t viewport_y = (bearing & 2) ? INT32_C(4194304) :
              -INT32_C(4194304);
          render_reference(reference, stride, width, height,
                           viewport_x, viewport_y, 16, 16,
                           sin_value, cos_value,
                           geometries[geometry][0], geometries[geometry][1],
                           fill != 0, 0xa5);
          render_optimized_current_zoom(
              optimized, stride, width, height, viewport_x, viewport_y,
              sin_value, cos_value,
              geometries[geometry][0], geometries[geometry][1],
              fill != 0, 0xa5);
          snprintf(label, sizeof(label),
                   "frame %dx%d tile %dx%d angle %d fill %d",
                   width, height, geometries[geometry][0], geometries[geometry][1],
                   bearings[bearing], fill);
          assert_framebuffers_equal(reference, optimized, active_size, label);
        }
      }
    }

    // Match the production fallback/current composition: the scaled source
    // pass fills, then the optimized current-zoom pass overlays only hits.
    fill_seed(reference, buffer_size, (uint32_t)(0x5000 + geometry));
    memcpy(optimized, reference, buffer_size);
    int32_t viewport_x = INT32_C(8388608);
    int32_t viewport_y = INT32_C(4194304);
    int32_t sin_value = sine_ratio(37);
    int32_t cos_value = cosine_ratio(37);
    render_reference(reference, stride, 200, 228,
                     viewport_x, viewport_y, 16, 15,
                     sin_value, cos_value,
                     geometries[geometry][0], geometries[geometry][1],
                     true, 0x5a);
    render_reference(optimized, stride, 200, 228,
                     viewport_x, viewport_y, 16, 15,
                     sin_value, cos_value,
                     geometries[geometry][0], geometries[geometry][1],
                     true, 0x5a);
    render_reference(reference, stride, 200, 228,
                     viewport_x, viewport_y, 16, 16,
                     sin_value, cos_value,
                     geometries[geometry][0], geometries[geometry][1],
                     false, 0x5a);
    render_optimized_current_zoom(
        optimized, stride, 200, 228, viewport_x, viewport_y,
        sin_value, cos_value,
        geometries[geometry][0], geometries[geometry][1], false, 0x5a);
    snprintf(label, sizeof(label), "fallback overlay tile %dx%d",
             geometries[geometry][0], geometries[geometry][1]);
    assert_framebuffers_equal(reference, optimized, buffer_size, label);
  }
  free(reference);
  free(optimized);
}

int main(void) {
  test_rounding_boundaries();
  test_step_decomposition_and_sequences();
  test_cardinals();
  test_exact_raster_bounds();
  test_coordinate_equivalence();
  test_cursor_equivalence();
  test_rle_cache_locality();
  test_framebuffer_equivalence();
  if (s_failures != 0) {
    fprintf(stderr, "rotated raster tests: %d failures\n", s_failures);
    return 1;
  }
  printf("rotated raster tests: all checks passed "
         "(coordinates=%" PRIu64 ", bytes=%" PRIu64 ")\n",
         s_coordinate_checks, s_byte_checks);
  return 0;
}
