#ifndef MAPPY_TILE_CODEC_H
#define MAPPY_TILE_CODEC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
  uint32_t pixel_index;
  uint32_t pixel_count;
  uint32_t packed_bytes;
  bool failed;
} TileRleStreamDecoder;

typedef enum {
  TileCompressionRle = 1,
  TileCompressionPacked = 2,
  TileCompressionLz4Packed = 3,
  TileCompressionLz4Rle = 4,
} TileCompressionFormat;

// An independent LZ4 block uses its output as history, without a dictionary
// allocation. Tokens may be split at any AppMessage boundary.
typedef struct {
  uint32_t output_bytes;
  uint32_t output_limit;
  uint32_t length;
  uint32_t last_match_start;
  uint16_t offset;
  uint8_t token;
  uint8_t state;
  bool had_match;
  bool failed;
} TileLz4StreamDecoder;

typedef union {
  TileRleStreamDecoder rle;
  TileLz4StreamDecoder lz4;
} TileStreamDecoder;

void tile_lz4_stream_init(TileLz4StreamDecoder *decoder, uint32_t output_limit);
bool tile_lz4_stream_feed(TileLz4StreamDecoder *decoder,
                          const uint8_t *encoded, size_t encoded_len,
                          uint8_t *output);
bool tile_lz4_stream_finish(const TileLz4StreamDecoder *decoder);

#define TILE_RLE_ROW_INDEX_BYTES 3
#define TILE_RLE_INDEX_BLOCK_PIXELS 32
#define TILE_RLE_INDEX_COLUMNS(width) \
  (((width) + TILE_RLE_INDEX_BLOCK_PIXELS - 1) / TILE_RLE_INDEX_BLOCK_PIXELS)
#define TILE_RLE_INDEX_BYTES(width, height) \
  ((size_t)(height) * TILE_RLE_INDEX_COLUMNS(width) * TILE_RLE_ROW_INDEX_BYTES)

void tile_rle_stream_init(TileRleStreamDecoder *decoder, uint32_t pixel_count,
                          uint8_t *packed, uint32_t packed_bytes);
bool tile_rle_stream_feed(TileRleStreamDecoder *decoder,
                          const uint8_t *encoded, size_t encoded_len,
                          uint8_t *packed);
bool tile_rle_stream_finish(const TileRleStreamDecoder *decoder);
bool tile_rle_decode(const uint8_t *encoded, size_t encoded_len,
                     uint32_t pixel_count, uint8_t *packed,
                     uint32_t packed_bytes);
bool tile_rle_build_row_index(const uint8_t *encoded, size_t encoded_len,
                              uint16_t width, uint16_t height,
                              uint8_t *row_index, size_t row_index_bytes);
bool tile_rle_sample_indexed(const uint8_t *encoded, size_t encoded_len,
                             const uint8_t *row_index,
                             size_t row_index_bytes, uint16_t width,
                             uint16_t height, uint16_t x, uint16_t y,
                             uint8_t *palette_index);
bool tile_rle_decode_indexed_row(const uint8_t *encoded, size_t encoded_len,
                                 const uint8_t *row_index,
                                 size_t row_index_bytes, uint16_t width,
                                 uint16_t height, uint16_t y,
                                 uint8_t *packed_row,
                                 size_t packed_row_bytes);
bool tile_rle_decode_indexed_block(const uint8_t *encoded, size_t encoded_len,
                                   const uint8_t *row_index,
                                   size_t row_index_bytes, uint16_t width,
                                   uint16_t height, uint16_t block,
                                   uint16_t y, uint8_t *packed_block,
                                   size_t packed_block_bytes);

#endif
