#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

#define SCREEN_W 200
#define SCREEN_H 228
#define TILE_W 54
#define TILE_H 63
#define TILE_CACHE_SIZE 42
#define TILE_BYTES (((TILE_W * TILE_H) + 1) / 2)
#define TRIG_MAX_RATIO 65536
#define TRIG_RATIO_SHIFT 16
#define FRAMES 180

typedef struct {
  int32_t world_x;
  int32_t world_y;
  int8_t zoom;
  uint8_t decoded[TILE_BYTES];
} TileEntry;

typedef struct {
  TileEntry *entry;
} LookupCell;

typedef struct {
  int32_t min_x;
  int32_t min_y;
  int cols;
  int rows;
  LookupCell cells[TILE_CACHE_SIZE];
} TileLookup;

static TileEntry s_entries[TILE_CACHE_SIZE];
static uint8_t s_framebuffer_linear[SCREEN_W * SCREEN_H];
static uint8_t s_framebuffer_lookup[SCREEN_W * SCREEN_H];
static const uint8_t s_palette[16] = {
  0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
  0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
};

static int32_t floor_div_i32(int32_t value, int32_t divisor) {
  int32_t quotient = value / divisor;
  int32_t remainder = value % divisor;
  if (remainder != 0 && ((remainder < 0) != (divisor < 0))) {
    quotient--;
  }
  return quotient;
}

static int32_t trig_ratio_to_nearest_int(int32_t value) {
  const int32_t half = (int32_t)1 << (TRIG_RATIO_SHIFT - 1);
  if (value >= 0) {
    return (value + half) >> TRIG_RATIO_SHIFT;
  }
  return -(((-value) + half) >> TRIG_RATIO_SHIFT);
}

static int32_t sin_ratio(double degrees) {
  return (int32_t)llround(sin(degrees * M_PI / 180.0) * TRIG_MAX_RATIO);
}

static int32_t cos_ratio(double degrees) {
  return (int32_t)llround(cos(degrees * M_PI / 180.0) * TRIG_MAX_RATIO);
}

static void fill_tile(TileEntry *entry, int index) {
  for (int i = 0; i < TILE_W * TILE_H; i += 2) {
    uint8_t low = (uint8_t)((index + i + entry->world_x + entry->world_y) & 0x0f);
    uint8_t high = (uint8_t)((index * 3 + i / 2) & 0x0f);
    entry->decoded[i / 2] = (uint8_t)(low | (high << 4));
  }
}

static int build_entries(int32_t viewport_x, int32_t viewport_y,
                         int32_t sin_value, int32_t cos_value) {
  int32_t half_w = SCREEN_W / 2;
  int32_t half_h = SCREEN_H / 2;
  const int32_t corners[4][2] = {
    {-1, -1}, {1, -1}, {1, 1}, {-1, 1},
  };
  int32_t min_x = INT32_MAX;
  int32_t max_x = INT32_MIN;
  int32_t min_y = INT32_MAX;
  int32_t max_y = INT32_MIN;
  for (int i = 0; i < 4; i++) {
    int32_t sx = corners[i][0] * half_w;
    int32_t sy = corners[i][1] * half_h;
    int32_t world_dx = trig_ratio_to_nearest_int(
        sx * cos_value - sy * sin_value);
    int32_t world_dy = trig_ratio_to_nearest_int(
        sx * sin_value + sy * cos_value);
    int32_t world_x = viewport_x + world_dx;
    int32_t world_y = viewport_y + world_dy;
    if (world_x < min_x) {
      min_x = world_x;
    }
    if (world_x > max_x) {
      max_x = world_x;
    }
    if (world_y < min_y) {
      min_y = world_y;
    }
    if (world_y > max_y) {
      max_y = world_y;
    }
  }

  int32_t start_x = floor_div_i32(min_x, TILE_W) * TILE_W;
  int32_t end_x = floor_div_i32(max_x, TILE_W) * TILE_W;
  int32_t start_y = floor_div_i32(min_y, TILE_H) * TILE_H;
  int32_t end_y = floor_div_i32(max_y, TILE_H) * TILE_H;
  int count = 0;
  for (int32_t y = start_y; y <= end_y && count < TILE_CACHE_SIZE; y += TILE_H) {
    for (int32_t x = start_x; x <= end_x && count < TILE_CACHE_SIZE; x += TILE_W) {
      s_entries[count].world_x = x;
      s_entries[count].world_y = y;
      s_entries[count].zoom = 16;
      fill_tile(&s_entries[count], count);
      count++;
    }
  }
  return count;
}

static int visible_tile_entry_index(TileEntry **entries, int entry_count,
                                    int32_t world_x, int32_t world_y) {
  int32_t origin_x = floor_div_i32(world_x, TILE_W) * TILE_W;
  int32_t origin_y = floor_div_i32(world_y, TILE_H) * TILE_H;
  for (int i = 0; i < entry_count; i++) {
    TileEntry *entry = entries[i];
    if (entry && entry->world_x == origin_x && entry->world_y == origin_y) {
      return i;
    }
  }
  return -1;
}

static int sample_linear(TileEntry **entries, int entry_count,
                         int32_t world_x, int32_t world_y,
                         uint8_t *palette_index) {
  int entry_index = visible_tile_entry_index(entries, entry_count, world_x, world_y);
  if (entry_index < 0) {
    return 0;
  }

  TileEntry *entry = entries[entry_index];
  int local_x = (int)(world_x - entry->world_x);
  int local_y = (int)(world_y - entry->world_y);
  if (local_x < 0 || local_x >= TILE_W || local_y < 0 || local_y >= TILE_H) {
    return 0;
  }
  int pixel_index = local_y * TILE_W + local_x;
  uint8_t packed = entry->decoded[pixel_index / 2];
  *palette_index = (pixel_index & 1) ? (packed >> 4) : (packed & 0x0f);
  return 1;
}

static int build_lookup(TileEntry **entries, int entry_count, TileLookup *lookup) {
  int32_t min_x = INT32_MAX;
  int32_t max_x = INT32_MIN;
  int32_t min_y = INT32_MAX;
  int32_t max_y = INT32_MIN;
  int valid_count = 0;

  for (int i = 0; i < entry_count; i++) {
    TileEntry *entry = entries[i];
    if (!entry) {
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

  lookup->cols = 0;
  lookup->rows = 0;
  if (valid_count == 0) {
    return 1;
  }

  int cols = (int)((max_x - min_x) / TILE_W) + 1;
  int rows = (int)((max_y - min_y) / TILE_H) + 1;
  if (cols <= 0 || rows <= 0 || cols * rows > TILE_CACHE_SIZE) {
    return 0;
  }

  lookup->min_x = min_x;
  lookup->min_y = min_y;
  lookup->cols = cols;
  lookup->rows = rows;
  memset(lookup->cells, 0, sizeof(lookup->cells));

  for (int i = 0; i < entry_count; i++) {
    TileEntry *entry = entries[i];
    if (!entry) {
      continue;
    }
    int col = (int)((entry->world_x - min_x) / TILE_W);
    int row = (int)((entry->world_y - min_y) / TILE_H);
    if (col >= 0 && col < cols && row >= 0 && row < rows) {
      lookup->cells[row * cols + col].entry = entry;
    }
  }
  return 1;
}

static inline int sample_lookup(const TileLookup *lookup, int col, int row,
                                int local_x, int local_y, uint8_t *palette_index) {
  if (lookup->cols <= 0 || lookup->rows <= 0) {
    return 0;
  }
  if (col < 0 || col >= lookup->cols || row < 0 || row >= lookup->rows ||
      local_x < 0 || local_x >= TILE_W || local_y < 0 || local_y >= TILE_H) {
    return 0;
  }
  TileEntry *entry = lookup->cells[row * lookup->cols + col].entry;
  if (!entry) {
    return 0;
  }

  int pixel_index = local_y * TILE_W + local_x;
  uint8_t packed = entry->decoded[pixel_index / 2];
  *palette_index = (pixel_index & 1) ? (packed >> 4) : (packed & 0x0f);
  return 1;
}

static inline void lookup_position(const TileLookup *lookup,
                                   int32_t world_x, int32_t world_y,
                                   int *col, int *row,
                                   int *local_x, int *local_y) {
  int32_t dx = world_x - lookup->min_x;
  int32_t dy = world_y - lookup->min_y;
  *col = floor_div_i32(dx, TILE_W);
  *row = floor_div_i32(dy, TILE_H);
  *local_x = (int)(dx - (int32_t)(*col) * TILE_W);
  *local_y = (int)(dy - (int32_t)(*row) * TILE_H);
}

static inline void advance_lookup_axis(int delta, int tile_size,
                                       int *cell_index, int *local) {
  *local += delta;
  if (*local < 0) {
    *local += tile_size;
    (*cell_index)--;
  } else if (*local >= tile_size) {
    *local -= tile_size;
    (*cell_index)++;
  }
}

static uint64_t render_linear(TileEntry **entries, int entry_count,
                              int32_t viewport_x, int32_t viewport_y,
                              int32_t sin_value, int32_t cos_value) {
  uint64_t checksum = 0;
  int center_x = SCREEN_W / 2;
  int center_y = SCREEN_H / 2;
  for (int screen_y = 0; screen_y < SCREEN_H; screen_y++) {
    int32_t sy = screen_y - center_y;
    int32_t sx = -center_x;
    int32_t world_x_num = sx * cos_value - sy * sin_value;
    int32_t world_y_num = sx * sin_value + sy * cos_value;
    for (int screen_x = 0; screen_x < SCREEN_W; screen_x++) {
      int32_t world_x = viewport_x + trig_ratio_to_nearest_int(world_x_num);
      int32_t world_y = viewport_y + trig_ratio_to_nearest_int(world_y_num);
      uint8_t palette_index;
      uint8_t out = 0;
      if (sample_linear(entries, entry_count, world_x, world_y, &palette_index)) {
        out = s_palette[palette_index & 0x0f];
      }
      s_framebuffer_linear[screen_y * SCREEN_W + screen_x] = out;
      checksum += (uint64_t)out + screen_x;
      world_x_num += cos_value;
      world_y_num += sin_value;
    }
  }
  return checksum;
}

static uint64_t render_lookup(TileEntry **entries, int entry_count,
                              int32_t viewport_x, int32_t viewport_y,
                              int32_t sin_value, int32_t cos_value) {
  TileLookup lookup;
  if (!build_lookup(entries, entry_count, &lookup)) {
    return render_linear(entries, entry_count, viewport_x, viewport_y,
                         sin_value, cos_value);
  }
  if (lookup.cols <= 0 || lookup.rows <= 0) {
    memset(s_framebuffer_lookup, 0, sizeof(s_framebuffer_lookup));
    return 0;
  }

  uint64_t checksum = 0;
  int center_x = SCREEN_W / 2;
  int center_y = SCREEN_H / 2;
  for (int screen_y = 0; screen_y < SCREEN_H; screen_y++) {
    int32_t sy = screen_y - center_y;
    int32_t sx = -center_x;
    int32_t world_x_num = sx * cos_value - sy * sin_value;
    int32_t world_y_num = sx * sin_value + sy * cos_value;
    int32_t world_x = viewport_x + trig_ratio_to_nearest_int(world_x_num);
    int32_t world_y = viewport_y + trig_ratio_to_nearest_int(world_y_num);
    int col;
    int row;
    int local_x;
    int local_y;
    lookup_position(&lookup, world_x, world_y, &col, &row, &local_x, &local_y);
    for (int screen_x = 0; screen_x < SCREEN_W; screen_x++) {
      uint8_t palette_index;
      uint8_t out = 0;
      if (sample_lookup(&lookup, col, row, local_x, local_y, &palette_index)) {
        out = s_palette[palette_index & 0x0f];
      }
      s_framebuffer_lookup[screen_y * SCREEN_W + screen_x] = out;
      checksum += (uint64_t)out + screen_x;
      world_x_num += cos_value;
      world_y_num += sin_value;
      int32_t next_world_x = viewport_x + trig_ratio_to_nearest_int(world_x_num);
      int32_t next_world_y = viewport_y + trig_ratio_to_nearest_int(world_y_num);
      advance_lookup_axis((int)(next_world_x - world_x), TILE_W, &col, &local_x);
      advance_lookup_axis((int)(next_world_y - world_y), TILE_H, &row, &local_y);
      world_x = next_world_x;
      world_y = next_world_y;
    }
  }
  return checksum;
}

static double monotonic_seconds(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

int main(void) {
  TileEntry *entries[TILE_CACHE_SIZE];
  uint64_t linear_checksum = 0;
  uint64_t lookup_checksum = 0;
  int mismatches = 0;
  int entry_count = 0;

  double start = monotonic_seconds();
  for (int frame = 0; frame < FRAMES; frame++) {
    double bearing = 11.0 + (double)(frame % 90);
    int32_t sin_value = sin_ratio(bearing);
    int32_t cos_value = cos_ratio(bearing);
    int32_t viewport_x = 8388608 + (frame % 20) - 10;
    int32_t viewport_y = 8388608 + ((frame * 3) % 20) - 10;
    entry_count = build_entries(viewport_x, viewport_y, sin_value, cos_value);
    for (int i = 0; i < entry_count; i++) {
      entries[i] = &s_entries[i];
    }
    linear_checksum += render_linear(entries, entry_count, viewport_x, viewport_y,
                                     sin_value, cos_value);
  }
  double linear_seconds = monotonic_seconds() - start;

  start = monotonic_seconds();
  for (int frame = 0; frame < FRAMES; frame++) {
    double bearing = 11.0 + (double)(frame % 90);
    int32_t sin_value = sin_ratio(bearing);
    int32_t cos_value = cos_ratio(bearing);
    int32_t viewport_x = 8388608 + (frame % 20) - 10;
    int32_t viewport_y = 8388608 + ((frame * 3) % 20) - 10;
    entry_count = build_entries(viewport_x, viewport_y, sin_value, cos_value);
    for (int i = 0; i < entry_count; i++) {
      entries[i] = &s_entries[i];
    }
    lookup_checksum += render_lookup(entries, entry_count, viewport_x, viewport_y,
                                     sin_value, cos_value);
  }
  double lookup_seconds = monotonic_seconds() - start;

  for (int i = 0; i < SCREEN_W * SCREEN_H; i++) {
    if (s_framebuffer_linear[i] != s_framebuffer_lookup[i]) {
      mismatches++;
    }
  }

  printf("frames=%d\n", FRAMES);
  printf("screen=%dx%d\n", SCREEN_W, SCREEN_H);
  printf("tile=%dx%d\n", TILE_W, TILE_H);
  printf("last_entry_count=%d\n", entry_count);
  printf("linear_seconds=%.6f\n", linear_seconds);
  printf("lookup_seconds=%.6f\n", lookup_seconds);
  printf("linear_ms_per_frame=%.3f\n", (linear_seconds * 1000.0) / FRAMES);
  printf("lookup_ms_per_frame=%.3f\n", (lookup_seconds * 1000.0) / FRAMES);
  printf("speedup=%.2fx\n", linear_seconds / lookup_seconds);
  printf("linear_checksum=%llu\n", (unsigned long long)linear_checksum);
  printf("lookup_checksum=%llu\n", (unsigned long long)lookup_checksum);
  printf("last_frame_mismatches=%d\n", mismatches);
  return mismatches == 0 && linear_checksum == lookup_checksum ? 0 : 1;
}
