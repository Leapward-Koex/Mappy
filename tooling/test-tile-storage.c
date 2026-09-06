#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "../apps/pebble-watch/src/c/tile_codec.h"
#include "../apps/pebble-watch/src/c/tile_storage.h"

// Compile the production pressure selector without the Pebble-dependent cache
// implementation.  This keeps the eviction-order regressions in the bounded
// host test while exercising the exact policy used on the watch.
#define MAPPY_H
#define MAPPY_TILE_CACHE_POLICY_HOST_TEST
#include "../apps/pebble-watch/src/c/tile_cache.c"
#undef MAPPY_TILE_CACHE_POLICY_HOST_TEST
#undef MAPPY_H

#define ARENA_BYTES (32 * 1024)
#define MAX_PIXELS (108 * 126)
#define MAX_PACKED ((MAX_PIXELS + 1) / 2)
#define MAX_INDEX_BYTES TILE_RLE_INDEX_BYTES(108, 126)

static int s_failures;

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: %s\n", message); \
    s_failures++; \
  } \
} while (0)

static size_t encode_pattern(int width, int height, uint8_t *pixels,
                             uint8_t *encoded) {
  int pixel_count = width * height;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      pixels[y * width + x] = (uint8_t)(((x / 7) + (y / 5)) & 0x0f);
    }
  }

  size_t encoded_len = 0;
  int cursor = 0;
  while (cursor < pixel_count) {
    uint8_t value = pixels[cursor];
    int run = 1;
    while (cursor + run < pixel_count && run < 16 &&
           pixels[cursor + run] == value) {
      run++;
    }
    encoded[encoded_len++] = (uint8_t)(((run - 1) << 4) | value);
    cursor += run;
  }
  return encoded_len;
}

static void test_geometry_round_trips(void) {
  const int geometries[][2] = {{54, 63}, {72, 84}, {108, 126}};
  uint8_t encoded[MAX_PIXELS];
  uint8_t packed[MAX_PACKED];
  uint8_t expected[MAX_PIXELS];
  uint8_t row_index[MAX_INDEX_BYTES];
  uint8_t packed_row[(108 + 1) / 2];
  uint8_t packed_block[TILE_RLE_INDEX_BLOCK_PIXELS / 2];
  for (size_t geometry = 0; geometry < 3; geometry++) {
    int width = geometries[geometry][0];
    int height = geometries[geometry][1];
    int pixels = width * height;
    int packed_bytes = (pixels + 1) / 2;
    size_t encoded_len = encode_pattern(width, height, expected, encoded);
    CHECK(tile_rle_decode(encoded, encoded_len, pixels, packed, packed_bytes),
          "pattern geometry should decode");
    CHECK(tile_rle_build_row_index(encoded, encoded_len, width, height,
                                   row_index, sizeof(row_index)),
          "pattern geometry should build a row index");
    for (int row = 0; row < height; row++) {
      CHECK(tile_rle_decode_indexed_row(
                encoded, encoded_len, row_index,
                TILE_RLE_INDEX_BYTES(width, height), width, height, row,
                packed_row, sizeof(packed_row)),
            "indexed RLE geometry should decode each row");
      for (int x = 0; x < width; x++) {
        uint8_t value = (x & 1) ? packed_row[x / 2] >> 4 :
                                  packed_row[x / 2] & 0x0f;
        CHECK(value == expected[row * width + x],
              "indexed row and source pixels should be identical");
      }
      int columns = TILE_RLE_INDEX_COLUMNS(width);
      for (int block = 0; block < columns; block++) {
        CHECK(tile_rle_decode_indexed_block(
                  encoded, encoded_len, row_index,
                  TILE_RLE_INDEX_BYTES(width, height), width, height, block,
                  row, packed_block, sizeof(packed_block)),
              "indexed RLE geometry should decode each block");
        int first_x = block * TILE_RLE_INDEX_BLOCK_PIXELS;
        int block_pixels = width - first_x;
        if (block_pixels > TILE_RLE_INDEX_BLOCK_PIXELS) {
          block_pixels = TILE_RLE_INDEX_BLOCK_PIXELS;
        }
        for (int x = 0; x < block_pixels; x++) {
          uint8_t value = (x & 1) ? packed_block[x / 2] >> 4 :
                                    packed_block[x / 2] & 0x0f;
          CHECK(value == expected[row * width + first_x + x],
                "indexed block and source pixels should be identical");
        }
      }
    }
    for (int i = 0; i < pixels; i++) {
      uint8_t value = (i & 1) ? packed[i / 2] >> 4 : packed[i / 2] & 0x0f;
      CHECK(value == expected[i],
            "packed geometry palette index should round-trip");
      uint8_t sampled = 0xff;
      CHECK(tile_rle_sample_indexed(encoded, encoded_len, row_index,
                                    TILE_RLE_INDEX_BYTES(width, height),
                                    width, height, i % width, i / width,
                                    &sampled),
            "indexed RLE geometry should sample");
      CHECK(sampled == expected[i],
            "indexed RLE and packed pixels should be identical");
    }

    TileRleStreamDecoder decoder;
    tile_rle_stream_init(&decoder, pixels, packed, packed_bytes);
    for (size_t i = 0; i < encoded_len; i++) {
      CHECK(tile_rle_stream_feed(&decoder, &encoded[i], 1, packed),
            "single-byte chunk should stream");
    }
    CHECK(tile_rle_stream_finish(&decoder),
          "single-byte chunk stream should finish exactly");
  }
}

static void test_high_entropy_packed_fallback(void) {
  uint8_t encoded[MAX_PIXELS];
  uint8_t packed[MAX_PACKED];
  for (int i = 0; i < MAX_PIXELS; i++) {
    encoded[i] = (uint8_t)(i & 0x0f);
  }
  CHECK(sizeof(encoded) > sizeof(packed),
        "high entropy RLE should be larger than packed storage");
  CHECK(tile_rle_decode(encoded, sizeof(encoded), MAX_PIXELS, packed,
                        sizeof(packed)),
        "high entropy tile should decode losslessly");
  for (int i = 0; i < MAX_PIXELS; i++) {
    uint8_t value = (i & 1) ? packed[i / 2] >> 4 : packed[i / 2] & 0x0f;
    CHECK(value == (i & 0x0f),
          "packed fallback should preserve every palette index");
  }
}

static void test_malformed_rle(void) {
  uint8_t packed[8];
  uint8_t row_index[2 * TILE_RLE_ROW_INDEX_BYTES];
  uint8_t packed_block[TILE_RLE_INDEX_BLOCK_PIXELS / 2];
  const uint8_t underfill[] = {0x31};
  const uint8_t overfill[] = {0xf1};
  CHECK(!tile_rle_decode(underfill, sizeof(underfill), 8, packed,
                         sizeof(packed)),
        "underfilled RLE should fail");
  CHECK(!tile_rle_decode(overfill, sizeof(overfill), 8, packed,
                         sizeof(packed)),
        "overfilled RLE should fail");
  CHECK(!tile_rle_build_row_index(underfill, sizeof(underfill), 4, 2,
                                  row_index, sizeof(row_index)),
        "underfilled RLE should not build a row index");
  CHECK(!tile_rle_build_row_index(overfill, sizeof(overfill), 4, 2,
                                  row_index, sizeof(row_index)),
        "overfilled RLE should not build a row index");
  CHECK(!tile_rle_decode_indexed_block(
            underfill, sizeof(underfill), row_index, sizeof(row_index), 4, 2,
            1, 0, packed_block, sizeof(packed_block)),
        "indexed block should reject an out-of-range block");
}

// Keep the baseline per-pixel implementation as an independent output oracle
// and timing comparison for the optimized packed-byte span decoder.
static bool baseline_decode_indexed_span(const uint8_t *encoded,
                                         size_t encoded_len,
                                         const uint8_t *row_index,
                                         size_t index_offset,
                                         uint16_t pixel_count,
                                         uint8_t *packed,
                                         size_t packed_bytes) {
  size_t required_bytes = (pixel_count + 1) / 2;
  if (!encoded || !row_index || !packed || pixel_count == 0 ||
      packed_bytes < required_bytes) {
    return false;
  }
  memset(packed, 0, required_bytes);
  size_t encoded_offset = row_index[index_offset] |
      ((size_t)row_index[index_offset + 1] << 8);
  uint8_t skip = row_index[index_offset + 2];
  uint16_t pixel = 0;
  while (encoded_offset < encoded_len && pixel < pixel_count) {
    uint8_t byte = encoded[encoded_offset++];
    uint16_t run_length = (byte >> 4) + 1;
    uint8_t palette_index = byte & 0x0f;
    if (skip >= run_length) {
      return false;
    }
    run_length -= skip;
    skip = 0;
    if (run_length > pixel_count - pixel) {
      run_length = pixel_count - pixel;
    }
    while (run_length-- > 0) {
      if (pixel & 1) {
        packed[pixel / 2] |= palette_index << 4;
      } else {
        packed[pixel / 2] = palette_index;
      }
      pixel++;
    }
  }
  return pixel == pixel_count;
}

static bool baseline_decode_indexed_block(
    const uint8_t *encoded, size_t encoded_len, const uint8_t *row_index,
    size_t row_index_bytes, uint16_t width, uint16_t height, uint16_t block,
    uint16_t y, uint8_t *packed, size_t packed_bytes) {
  uint16_t columns = TILE_RLE_INDEX_COLUMNS(width);
  if (!encoded || !row_index || !packed || width == 0 || y >= height ||
      block >= columns ||
      row_index_bytes < TILE_RLE_INDEX_BYTES(width, height)) {
    return false;
  }
  uint16_t pixel_count = width - block * TILE_RLE_INDEX_BLOCK_PIXELS;
  if (pixel_count > TILE_RLE_INDEX_BLOCK_PIXELS) {
    pixel_count = TILE_RLE_INDEX_BLOCK_PIXELS;
  }
  size_t index_offset = ((size_t)y * columns + block) *
      TILE_RLE_ROW_INDEX_BYTES;
  return baseline_decode_indexed_span(encoded, encoded_len, row_index,
      index_offset, pixel_count, packed, packed_bytes);
}

static uint32_t span_random(uint32_t *state) {
  *state = *state * UINT32_C(1664525) + UINT32_C(1013904223);
  return *state;
}

// Include single-pixel transitions, short runs, full runs, and mostly uniform
// backgrounds with occasional one-pixel features; runs may cross row edges.
static size_t encode_span_pattern(uint16_t width, uint16_t height,
                                  unsigned pattern, uint32_t *seed,
                                  uint8_t *pixels, uint8_t *encoded) {
  uint32_t count = (uint32_t)width * height;
  uint32_t pixel = 0;
  size_t length = 0;
  while (pixel < count) {
    uint32_t random = span_random(seed);
    uint32_t run = pattern == 0 ? 1 : pattern == 1 ? 1 + (random >> 16) % 4 :
        pattern == 2 ? 12 + (random >> 16) % 5 :
        ((random >> 16) % 11 == 0 ? 1 : 16);
    if (run > count - pixel) {
      run = count - pixel;
    }
    uint8_t color = pattern == 3 && run > 1 ? 0 : (random >> 8) & 0x0f;
    encoded[length++] = (uint8_t)(((run - 1) << 4) | color);
    memset(pixels + pixel, color, run);
    pixel += run;
  }
  return length;
}

static void test_indexed_span_reference_and_bounds(void) {
  const uint16_t widths[] = {
      1, 2, 3, 15, 16, 17, 31, 32, 33, 53, 54, 63, 64, 65,
      71, 72, 107, 108, 109, 127, 128, 129};
  uint8_t encoded[129 * 13];
  uint8_t pixels[sizeof(encoded)];
  uint8_t index[TILE_RLE_INDEX_BYTES(129, 13)];
  uint8_t actual[8 + 65 + 8];
  uint8_t expected[sizeof(actual)];
  uint32_t seed = UINT32_C(0x5319fa27);
  for (unsigned pattern = 0; pattern < 4; pattern++) {
    for (unsigned iteration = 0; iteration < 132; iteration++) {
      uint16_t width = widths[iteration % (sizeof(widths) / sizeof(widths[0]))];
      uint16_t height = 1 + (span_random(&seed) >> 16) % 13;
      size_t length = encode_span_pattern(width, height, pattern, &seed,
                                          pixels, encoded);
      size_t index_bytes = TILE_RLE_INDEX_BYTES(width, height);
      CHECK(tile_rle_build_row_index(encoded, length, width, height, index,
                                     index_bytes),
            "random RLE should build row checkpoints");
      for (uint16_t y = 0; y < height; y++) {
        memset(actual, 0xa5, sizeof(actual));
        memset(expected, 0xa5, sizeof(expected));
        size_t offset = (size_t)y * TILE_RLE_INDEX_COLUMNS(width) *
            TILE_RLE_ROW_INDEX_BYTES;
        bool reference_ok = baseline_decode_indexed_span(encoded, length,
            index, offset, width, expected + 8, 65);
        CHECK(tile_rle_decode_indexed_row(encoded, length, index, index_bytes,
                  width, height, y, actual + 8, 65) == reference_ok,
              "random indexed row should match baseline success");
        CHECK(memcmp(actual, expected, sizeof(actual)) == 0,
              "random row must match every baseline byte and buffer guard");
        for (uint16_t x = 0; x < width; x++) {
          uint8_t value = actual[8 + x / 2] >> ((x & 1) * 4);
          CHECK((value & 0x0f) == pixels[(size_t)y * width + x],
                "random row should match independently expanded source");
        }
        if (width & 1) {
          CHECK((actual[8 + width / 2] & 0xf0) == 0,
                "odd row must leave the final high nibble zero");
        }
        for (uint16_t block = 0; block < TILE_RLE_INDEX_COLUMNS(width); block++) {
          memset(actual, 0xa5, sizeof(actual));
          memset(expected, 0xa5, sizeof(expected));
          reference_ok = baseline_decode_indexed_block(encoded, length,
              index, index_bytes, width, height, block, y, expected + 8, 65);
          CHECK(tile_rle_decode_indexed_block(encoded, length, index,
                    index_bytes, width, height, block, y, actual + 8, 65) ==
                    reference_ok,
                "random indexed block should match baseline success");
          CHECK(memcmp(actual, expected, sizeof(actual)) == 0,
                "random block must match baseline bytes and buffer guards");
        }
      }
    }
  }
}

static void test_indexed_span_malformed_contract(void) {
  uint8_t actual[8 + 16 + 8];
  uint8_t expected[sizeof(actual)];
  uint8_t index[TILE_RLE_ROW_INDEX_BYTES];
  uint8_t encoded[32];
  uint32_t seed = UINT32_C(0x629cd101);
  // Include invalid skips, offsets past the stream, truncation after partial
  // output, and insufficient output capacity. Compare failure output too.
  for (unsigned trial = 0; trial < 6000; trial++) {
    for (size_t i = 0; i < sizeof(encoded); i++) {
      encoded[i] = (uint8_t)(span_random(&seed) >> 16);
    }
    uint16_t width = 1 + (span_random(&seed) >> 16) % 32;
    size_t length = (span_random(&seed) >> 16) % 33;
    index[0] = (uint8_t)((span_random(&seed) >> 16) % 35);
    index[1] = trial % 13 == 0 ? 1 : 0;
    index[2] = (uint8_t)((span_random(&seed) >> 16) % 18);
    size_t packed_bytes = trial % 7 == 0 ? (width - 1) / 2 : 16;
    size_t index_bytes = trial % 11 == 0 ? 2 : sizeof(index);
    const uint8_t *input = trial % 17 == 0 ? NULL : encoded;
    const uint8_t *checkpoints = trial % 19 == 0 ? NULL : index;
    memset(actual, 0xa5, sizeof(actual));
    memset(expected, 0xa5, sizeof(expected));
    bool reference_ok = baseline_decode_indexed_block(input, length,
        checkpoints, index_bytes, width, 1, 0, 0, expected + 8, packed_bytes);
    CHECK(tile_rle_decode_indexed_block(input, length, checkpoints, index_bytes,
              width, 1, 0, 0, actual + 8, packed_bytes) == reference_ok,
          "malformed indexed span should preserve baseline return contract");
    CHECK(memcmp(actual, expected, sizeof(actual)) == 0,
          "malformed span should preserve partial output and buffer guards");
  }
  memset(actual, 0xa5, sizeof(actual));
  memset(expected, 0xa5, sizeof(expected));
  CHECK(!tile_rle_decode_indexed_row(encoded, sizeof(encoded), index,
            sizeof(index), 0, 1, 0, actual + 8, 16),
        "zero-width row should be rejected");
  CHECK(!tile_rle_decode_indexed_row(encoded, sizeof(encoded), index,
            sizeof(index), 8, 0, 0, actual + 8, 16),
        "zero-height row should be rejected");
  CHECK(!tile_rle_decode_indexed_block(encoded, sizeof(encoded), index,
            sizeof(index), 8, 1, 0, 0, NULL, 16),
        "null block destination should be rejected");
  CHECK(memcmp(actual, expected, sizeof(actual)) == 0,
        "invalid dimensions must leave output untouched");
}

typedef bool (*SpanBlockDecoder)(const uint8_t *, size_t, const uint8_t *,
    size_t, uint16_t, uint16_t, uint16_t, uint16_t, uint8_t *, size_t);

static double benchmark_indexed_blocks(SpanBlockDecoder implementation,
    const uint8_t *encoded, size_t length, const uint8_t *index,
    uint16_t width, uint16_t height, uint32_t *checksum) {
  // Volatile dispatch gives both implementations the same call boundary and
  // prevents the local baseline from gaining benchmark-only inlining.
  SpanBlockDecoder volatile decode = implementation;
  uint8_t packed[TILE_RLE_INDEX_BLOCK_PIXELS / 2];
  uint32_t sum = 0;
  clock_t started = clock();
  for (unsigned repetition = 0; repetition < 15000; repetition++) {
    for (uint16_t y = 0; y < height; y++) {
      for (uint16_t block = 0; block < TILE_RLE_INDEX_COLUMNS(width); block++) {
        bool decoded = decode(encoded, length, index,
            TILE_RLE_INDEX_BYTES(width, height), width, height, block, y,
            packed, sizeof(packed));
        uint16_t pixels = width - block * TILE_RLE_INDEX_BLOCK_PIXELS;
        if (pixels > TILE_RLE_INDEX_BLOCK_PIXELS) {
          pixels = TILE_RLE_INDEX_BLOCK_PIXELS;
        }
        sum += decoded + packed[0] + packed[(pixels - 1) / 2];
      }
    }
  }
  *checksum = sum;
  return (double)(clock() - started) / CLOCKS_PER_SEC;
}

static void benchmark_indexed_span_patterns(void) {
  const uint16_t geometries[][2] = {{54, 63}, {72, 84}, {108, 126}};
  const char *names[] = {"single", "short", "long", "sparse"};
  uint8_t encoded[MAX_PIXELS];
  uint8_t pixels[MAX_PIXELS];
  uint8_t index[MAX_INDEX_BYTES];
  for (unsigned geometry = 0; geometry < 3; geometry++) {
    uint16_t width = geometries[geometry][0];
    uint16_t height = geometries[geometry][1];
    for (unsigned pattern = 0; pattern < 4; pattern++) {
      uint32_t seed = UINT32_C(0x915fb647);
      size_t length = encode_span_pattern(width, height, pattern, &seed,
                                          pixels, encoded);
      CHECK(tile_rle_build_row_index(encoded, length, width, height, index,
                                     sizeof(index)),
            "benchmark data should build row checkpoints");
      uint32_t baseline_sum;
      uint32_t packed_sum;
      double baseline_s = benchmark_indexed_blocks(baseline_decode_indexed_block,
          encoded, length, index, width, height, &baseline_sum);
      double packed_s = benchmark_indexed_blocks(tile_rle_decode_indexed_block,
          encoded, length, index, width, height, &packed_sum);
      CHECK(baseline_sum == packed_sum, "benchmark outputs should match");
      printf("RLE span tile=%ux%u pattern=%s baseline_ms=%.3f packed_ms=%.3f speedup=%.2fx checksum=%u\n",
          width, height, names[pattern], baseline_s * 1000, packed_s * 1000,
          packed_s > 0 ? baseline_s / packed_s : 0, packed_sum);
    }
  }
}

static void test_arena_compaction_and_bound(void) {
  uint8_t bytes[ARENA_BYTES];
  TileStorageArena arena;
  TileStorageRef refs[42];
  tile_storage_arena_init(&arena, bytes, sizeof(bytes));
  for (size_t i = 0; i < 42; i++) {
    tile_storage_ref_reset(&refs[i]);
  }

  CHECK(tile_storage_arena_reserve(&arena, &refs[0], 100,
                                   TileStorageIndexedRle),
        "first segment should reserve");
  CHECK(tile_storage_arena_reserve(&arena, &refs[1], 200, TileStoragePacked),
        "second segment should reserve");
  CHECK(tile_storage_arena_reserve(&arena, &refs[2], 300,
                                   TileStorageIndexedRle),
        "third segment should reserve");
  memset(tile_storage_mutable_data(&arena, &refs[0]), 0x11, refs[0].length);
  memset(tile_storage_mutable_data(&arena, &refs[1]), 0x22, refs[1].length);
  memset(tile_storage_mutable_data(&arena, &refs[2]), 0x33, refs[2].length);
  tile_storage_arena_remove(&arena, &refs[1], refs, 42,
                            sizeof(TileStorageRef));
  CHECK(arena.used == 400, "arena remove should reclaim exact bytes");
  CHECK(refs[2].offset == 100, "later segment offset should compact");
  CHECK(tile_storage_data(&arena, &refs[2])[0] == 0x33,
        "compaction should preserve later segment data");

  tile_storage_arena_reset(&arena);
  for (size_t i = 0; i < 42; i++) {
    tile_storage_ref_reset(&refs[i]);
  }
  CHECK(tile_storage_arena_reserve(&arena, &refs[0], ARENA_BYTES,
                                   TileStoragePacked),
        "arena should allow its exact hard bound");
  CHECK(!tile_storage_arena_reserve(&arena, &refs[1], 1,
                                    TileStorageIndexedRle),
        "arena must reject a byte beyond its hard bound");
  CHECK(arena.used == ARENA_BYTES, "arena usage must remain bounded");

  tile_storage_arena_reset(&arena);
  for (size_t i = 0; i < 42; i++) {
    tile_storage_ref_reset(&refs[i]);
  }
  CHECK(arena.used == 0, "invalidation should empty arena usage");
  CHECK(!tile_storage_ref_valid(&refs[0]),
        "invalidation should leave entries without storage");
}

static void test_eviction_policy(void) {
  TileStorageEvictionCandidate candidates[] = {
    {.eligible = true, .visible = true, .last_used = 1},
    {.eligible = true, .visible = false, .last_used = 20},
    {.eligible = true, .visible = false, .last_used = 10},
    {.eligible = false, .visible = false, .last_used = 0},
  };
  CHECK(tile_storage_select_eviction(candidates, 4) == 2,
        "eviction should prefer the oldest offscreen entry");
  candidates[1].eligible = false;
  candidates[2].eligible = false;
  CHECK(tile_storage_select_eviction(candidates, 4) == 0,
        "eviction should fall back to the oldest visible entry");
  candidates[0].eligible = false;
  CHECK(tile_storage_select_eviction(candidates, 4) == -1,
        "eviction should report no eligible entry");
}

static void test_cache_pressure_prefers_zoom_fallback(void) {
  TileCachePressureCandidate candidates[] = {
    {
      .priority = TileCachePressureLessImportantVisible,
      .distance_sq = 400,
      .last_used = 1,
    },
    {
      .priority = TileCachePressureFallback,
      .distance_sq = 100,
      .last_used = 20,
    },
    {
      .priority = TileCachePressureCoveredFallback,
      .distance_sq = 200,
      .last_used = 30,
    },
  };
  CHECK(tile_cache_select_pressure_candidate(candidates, 3, 25, true) == 2,
        "covered zoom fallback should be evicted before a visible current tile");

  candidates[2].priority = TileCachePressureIneligible;
  CHECK(tile_cache_select_pressure_candidate(candidates, 3, 25, true) == 1,
        "any retained zoom fallback should be evicted before visible current imagery");
}

static void test_cache_pressure_preserves_more_important_visible_tiles(void) {
  TileCachePressureCandidate candidates[] = {
    {
      .priority = TileCachePressureLessImportantVisible,
      .distance_sq = 25,
      .last_used = 1,
    },
    {
      .priority = TileCachePressureLessImportantVisible,
      .distance_sq = 400,
      .last_used = 2,
    },
  };
  CHECK(tile_cache_select_pressure_candidate(candidates, 2, 625, true) == -1,
        "a fringe arrival must not evict a more central rendered tile");
  CHECK(tile_cache_select_pressure_candidate(candidates, 2, 16, true) == 1,
        "a central arrival may replace the farthest less-important tile");

  candidates[0].distance_sq = 400;
  CHECK(tile_cache_select_pressure_candidate(candidates, 2, 400, true) == -1,
        "equal-importance visible tiles should not churn under pressure");
}

static void test_cache_pressure_reuses_existing_holes_first(void) {
  TileCachePressureCandidate candidates[] = {
    {
      .priority = TileCachePressureLessImportantVisible,
      .distance_sq = 900,
      .last_used = 1,
    },
    {
      .priority = TileCachePressureSuppressedVisible,
      .distance_sq = 25,
      .last_used = 50,
    },
    {
      .priority = TileCachePressureOffscreen,
      .distance_sq = 100,
      .last_used = 60,
    },
  };
  CHECK(tile_cache_select_pressure_candidate(candidates, 3, 4, true) == 2,
        "offscreen storage should remain the first pressure victim");
  candidates[2].priority = TileCachePressureIneligible;
  CHECK(tile_cache_select_pressure_candidate(candidates, 3, 4, true) == 1,
        "an existing visible hole should be reused before making another one");
}

static void test_cache_pressure_prioritizes_exact_render_tiles(void) {
  TileCachePressureCandidate candidates[] = {
    {
      .priority = TileCachePressureLessImportantVisible,
      .distance_sq = 400,
      .last_used = 1,
    },
    {
      .priority = TileCachePressureRequestPrefetch,
      .distance_sq = 100,
      .last_used = 2,
    },
  };
  CHECK(tile_cache_select_pressure_candidate(candidates, 2, 900, true) == 1,
        "an exact-render arrival must evict request-envelope prefetch first");
  CHECK(tile_cache_select_pressure_candidate(candidates, 2, 50, false) == 1,
        "a prefetch arrival may replace only a less useful prefetch tile");
  candidates[1].priority = TileCachePressureIneligible;
  CHECK(tile_cache_select_pressure_candidate(candidates, 2, 50, false) == -1,
        "a prefetch arrival must never displace exact-render imagery");
}

int main(int argc, char **argv) {
  test_geometry_round_trips();
  test_high_entropy_packed_fallback();
  test_malformed_rle();
  test_indexed_span_reference_and_bounds();
  test_indexed_span_malformed_contract();
  if (argc > 1 && strcmp(argv[1], "--benchmark") == 0) {
    benchmark_indexed_span_patterns();
  }
  test_arena_compaction_and_bound();
  test_eviction_policy();
  test_cache_pressure_prefers_zoom_fallback();
  test_cache_pressure_preserves_more_important_visible_tiles();
  test_cache_pressure_reuses_existing_holes_first();
  test_cache_pressure_prioritizes_exact_render_tiles();
  if (s_failures > 0) {
    fprintf(stderr, "tile storage tests: %d failure(s)\n", s_failures);
    return 1;
  }
  puts("tile storage tests: all checks passed");
  return 0;
}
