#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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

int main(void) {
  test_geometry_round_trips();
  test_high_entropy_packed_fallback();
  test_malformed_rle();
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
