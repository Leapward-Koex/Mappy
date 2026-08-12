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
