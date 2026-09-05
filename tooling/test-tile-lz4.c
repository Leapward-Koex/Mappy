#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../apps/pebble-watch/src/c/tile_codec.h"

#define CHECK(value) do { if (!(value)) { \
  fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); exit(1); \
} } while (0)
#define MAX_PACKED 6804

typedef struct {
  const char *name;
  int width, height, format;
  const uint8_t *payload;
  size_t payload_len;
  const uint8_t *packed;
  size_t packed_len;
} CodecVector;
#ifdef MAPPY_CODEC_GOLDENS
#include "tile-codec-vectors.generated.h"
#endif

static bool decode_lz4(const uint8_t *input, size_t size, uint8_t *output,
                        uint32_t bound, size_t split, size_t *written) {
  TileLz4StreamDecoder decoder;
  tile_lz4_stream_init(&decoder, bound);
  for (size_t offset = 0; offset < size;) {
    size_t count = split < size - offset ? split : size - offset;
    if (!tile_lz4_stream_feed(&decoder, input + offset, count, output)) {
      return false;
    }
    offset += count;
  }
  *written = decoder.output_bytes;
  return tile_lz4_stream_finish(&decoder);
}

static void test_stream_boundaries(void) {
  CHECK(sizeof(TileLz4StreamDecoder) <= 64);
  const uint8_t matched[] = {0x18, 'a', 1, 0, 0x50, 'b','c','d','e','f'};
  const uint8_t extended[] = {0x1f, 'a', 1, 0, 255, 25, 0x50,'b','c','d','e','f'};
  uint8_t output[306];
  for (size_t split = 1; split <= sizeof(matched); split++) {
    size_t written = 0;
    memset(output, 0xa5, sizeof(output));
    CHECK(decode_lz4(matched, sizeof(matched), output, 18, split, &written));
    CHECK(written == 18 && output[18] == 0xa5);
    for (size_t i = 0; i < 13; i++) CHECK(output[i] == 'a');
    CHECK(memcmp(output + 13, "bcdef", 5) == 0);
    CHECK(decode_lz4(extended, sizeof(extended), output, 305, split, &written));
    CHECK(written == 305 && output[305] == 0xa5);
    for (size_t i = 0; i < 300; i++) CHECK(output[i] == 'a');
    CHECK(memcmp(output + 300, "bcdef", 5) == 0);
  }
  const uint8_t malformed[][16] = {
    {0}, {0x10,'a',0,0,0x50,'b','c','d','e','f'},
    {0x10,'a',2,0,0x50,'b','c','d','e','f'},
    {0x18,'a',1}, {0x18,'a',1,0}, {0x18,'a',1,0,0},
    {0xf0,255,255,255}, {0x1f,'a',1,0,255,255,255},
    {0x18,'a',1,0,0x40,'b','c','d','e'},
  };
  const size_t lengths[] = {1,10,10,3,4,5,4,7,9};
  for (size_t i = 0; i < sizeof(lengths)/sizeof(lengths[0]); i++) {
    size_t written = 0;
    CHECK(!decode_lz4(malformed[i], lengths[i], output, 305, 1, &written));
  }
  size_t written = 0;
  CHECK(!decode_lz4(matched, sizeof(matched), output, 17, 1, &written));
}

#ifdef MAPPY_CODEC_GOLDENS
static void test_golden(const CodecVector *vector) {
  uint32_t pixels = vector->width * vector->height;
  size_t packed_bytes = (pixels + 1) / 2;
  size_t index_bytes = TILE_RLE_INDEX_BYTES(vector->width, vector->height);
  uint8_t scratch[MAX_PACKED + 1];
  uint8_t actual[MAX_PACKED];
  uint8_t row[54];
  CHECK(packed_bytes == vector->packed_len && packed_bytes <= MAX_PACKED);
  // Exercise every possible uniform chunk length, including single-byte
  // chunks and splits within both extended lengths and backreferences.
  for (size_t split = 1; split <= vector->payload_len; split++) {
    memset(scratch, 0xa5, sizeof(scratch));
    size_t encoded_bytes = vector->payload_len;
    bool indexed = vector->format == 4 ||
        (vector->format == 1 && encoded_bytes + index_bytes < packed_bytes);
    if (vector->format == 3 || vector->format == 4) {
      size_t bound = vector->format == 3 ? packed_bytes :
          packed_bytes - index_bytes - 1;
      CHECK(decode_lz4(vector->payload, vector->payload_len, scratch,
                       bound, split, &encoded_bytes));
      CHECK(scratch[bound] == 0xa5);
      if (vector->format == 3) CHECK(encoded_bytes == packed_bytes);
    } else if (vector->format == 2 || indexed) {
      CHECK(encoded_bytes <= packed_bytes);
      memcpy(scratch, vector->payload, encoded_bytes);
    } else {
      TileRleStreamDecoder decoder;
      tile_rle_stream_init(&decoder, pixels, scratch, packed_bytes);
      for (size_t offset = 0; offset < encoded_bytes;) {
        size_t count = split < encoded_bytes - offset ? split : encoded_bytes - offset;
        CHECK(tile_rle_stream_feed(&decoder, vector->payload + offset,
                                   count, scratch));
        offset += count;
      }
      CHECK(tile_rle_stream_finish(&decoder));
    }
    if (indexed) {
      CHECK(encoded_bytes + index_bytes < packed_bytes);
      CHECK(tile_rle_build_row_index(scratch, encoded_bytes,
                                     vector->width, vector->height,
                                     scratch + encoded_bytes, index_bytes));
      for (int y = 0; y < vector->height; y++) {
        CHECK(tile_rle_decode_indexed_row(scratch, encoded_bytes,
            scratch + encoded_bytes, index_bytes, vector->width,
            vector->height, y, row, sizeof(row)));
        memcpy(actual + y * vector->width / 2, row, vector->width / 2);
      }
    } else {
      memcpy(actual, scratch, packed_bytes);
    }
    CHECK(memcmp(actual, vector->packed, packed_bytes) == 0);
    CHECK(scratch[packed_bytes] == 0xa5);
  }
  printf("codec vector %s: format=%d bytes=%zu pixels=%u\n",
         vector->name, vector->format, vector->payload_len, pixels);
}
#endif

static void test_malformed_fuzz(void) {
  uint32_t random = 0x5a17c0de;
  uint8_t encoded[256];
  uint8_t guarded[MAX_PACKED + 2];
  for (int sample = 0; sample < 10000; sample++) {
    for (size_t i = 0; i < sizeof(encoded); i++) {
      random = random * 1664525u + 1013904223u;
      encoded[i] = (uint8_t)(random >> 24);
    }
    memset(guarded, 0xa5, sizeof(guarded));
    size_t written = 0;
    size_t size = 1 + random % sizeof(encoded);
    size_t bound = 1 + (random >> 8) % MAX_PACKED;
    (void)decode_lz4(encoded, size, guarded + 1, bound,
                     1 + random % 19, &written);
    CHECK(guarded[0] == 0xa5 && guarded[bound + 1] == 0xa5);
  }
}

int main(void) {
  test_malformed_fuzz();
  test_stream_boundaries();
#ifdef MAPPY_CODEC_GOLDENS
  for (size_t i = 0; i < sizeof(s_vectors)/sizeof(s_vectors[0]); i++) {
    test_golden(&s_vectors[i]);
  }
#endif
  puts("tile LZ4 codec: passed");
  return 0;
}
