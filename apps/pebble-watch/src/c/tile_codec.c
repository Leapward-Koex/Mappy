#include "tile_codec.h"

#include <string.h>

void tile_rle_stream_init(TileRleStreamDecoder *decoder, uint32_t pixel_count,
                          uint8_t *packed, uint32_t packed_bytes) {
  if (!decoder) {
    return;
  }
  decoder->pixel_index = 0;
  decoder->pixel_count = pixel_count;
  decoder->packed_bytes = packed_bytes;
  decoder->failed = !packed || pixel_count == 0 ||
      packed_bytes < (pixel_count + 1) / 2;
  if (!decoder->failed) {
    memset(packed, 0, packed_bytes);
  }
}

bool tile_rle_stream_feed(TileRleStreamDecoder *decoder,
                          const uint8_t *encoded, size_t encoded_len,
                          uint8_t *packed) {
  if (!decoder || decoder->failed || !encoded || !packed || encoded_len == 0) {
    if (decoder) {
      decoder->failed = true;
    }
    return false;
  }

  for (size_t i = 0; i < encoded_len; i++) {
    uint32_t run_length = (encoded[i] >> 4) + 1;
    uint8_t palette_index = encoded[i] & 0x0f;
    if (decoder->pixel_index + run_length > decoder->pixel_count) {
      decoder->failed = true;
      return false;
    }

    if ((decoder->pixel_index & 1) && run_length > 0) {
      packed[decoder->pixel_index / 2] |= palette_index << 4;
      decoder->pixel_index++;
      run_length--;
    }
    uint8_t packed_pair = palette_index | (palette_index << 4);
    while (run_length >= 2) {
      packed[decoder->pixel_index / 2] = packed_pair;
      decoder->pixel_index += 2;
      run_length -= 2;
    }
    if (run_length > 0) {
      packed[decoder->pixel_index / 2] = palette_index;
      decoder->pixel_index++;
    }
  }
  return true;
}

bool tile_rle_stream_finish(const TileRleStreamDecoder *decoder) {
  return decoder && !decoder->failed &&
      decoder->pixel_index == decoder->pixel_count;
}

bool tile_rle_decode(const uint8_t *encoded, size_t encoded_len,
                     uint32_t pixel_count, uint8_t *packed,
                     uint32_t packed_bytes) {
  TileRleStreamDecoder decoder;
  tile_rle_stream_init(&decoder, pixel_count, packed, packed_bytes);
  return tile_rle_stream_feed(&decoder, encoded, encoded_len, packed) &&
      tile_rle_stream_finish(&decoder);
}

bool tile_rle_build_row_index(const uint8_t *encoded, size_t encoded_len,
                              uint16_t width, uint16_t height,
                              uint8_t *row_index, size_t row_index_bytes) {
  if (!encoded || encoded_len == 0 || width == 0 || height == 0 ||
      !row_index || row_index_bytes < TILE_RLE_INDEX_BYTES(width, height)) {
    return false;
  }
  size_t encoded_offset = 0;
  uint32_t run_start = 0;
  uint32_t pixel_count = (uint32_t)width * height;
  for (uint16_t row = 0; row < height; row++) {
    uint16_t columns = TILE_RLE_INDEX_COLUMNS(width);
    for (uint16_t column = 0; column < columns; column++) {
      uint32_t checkpoint = (uint32_t)row * width +
          (uint32_t)column * TILE_RLE_INDEX_BLOCK_PIXELS;
      while (encoded_offset < encoded_len) {
        uint32_t run_length = (encoded[encoded_offset] >> 4) + 1;
        if (checkpoint < run_start + run_length) {
          break;
        }
        run_start += run_length;
        encoded_offset++;
      }
      if (encoded_offset >= encoded_len || encoded_offset > UINT16_MAX) {
        return false;
      }
      uint32_t skip = checkpoint - run_start;
      if (skip > 15) {
        return false;
      }
      size_t index_offset = ((size_t)row * columns + column) *
          TILE_RLE_ROW_INDEX_BYTES;
      row_index[index_offset] = (uint8_t)(encoded_offset & 0xff);
      row_index[index_offset + 1] =
          (uint8_t)((encoded_offset >> 8) & 0xff);
      row_index[index_offset + 2] = (uint8_t)skip;
    }
  }

  while (encoded_offset < encoded_len) {
    run_start += (encoded[encoded_offset] >> 4) + 1;
    encoded_offset++;
  }
  return run_start == pixel_count;
}

bool tile_rle_sample_indexed(const uint8_t *encoded, size_t encoded_len,
                             const uint8_t *row_index,
                             size_t row_index_bytes, uint16_t width,
                             uint16_t height, uint16_t x, uint16_t y,
                             uint8_t *palette_index) {
  if (!encoded || !row_index || !palette_index || x >= width || y >= height ||
      row_index_bytes < TILE_RLE_INDEX_BYTES(width, height)) {
    return false;
  }
  uint16_t columns = TILE_RLE_INDEX_COLUMNS(width);
  uint16_t column = x / TILE_RLE_INDEX_BLOCK_PIXELS;
  size_t index_offset = ((size_t)y * columns + column) *
      TILE_RLE_ROW_INDEX_BYTES;
  size_t encoded_offset = row_index[index_offset] |
      ((size_t)row_index[index_offset + 1] << 8);
  uint8_t skip = row_index[index_offset + 2];
  uint32_t remaining_x = x % TILE_RLE_INDEX_BLOCK_PIXELS;
  while (encoded_offset < encoded_len) {
    uint8_t byte = encoded[encoded_offset++];
    uint32_t run_length = (byte >> 4) + 1;
    if (skip >= run_length) {
      return false;
    }
    run_length -= skip;
    skip = 0;
    if (remaining_x < run_length) {
      *palette_index = byte & 0x0f;
      return true;
    }
    remaining_x -= run_length;
  }
  return false;
}

bool tile_rle_decode_indexed_row(const uint8_t *encoded, size_t encoded_len,
                                 const uint8_t *row_index,
                                 size_t row_index_bytes, uint16_t width,
                                 uint16_t height, uint16_t y,
                                 uint8_t *packed_row,
                                 size_t packed_row_bytes) {
  size_t required_bytes = (width + 1) / 2;
  if (!encoded || !row_index || !packed_row || width == 0 || y >= height ||
      packed_row_bytes < required_bytes ||
      row_index_bytes < TILE_RLE_INDEX_BYTES(width, height)) {
    return false;
  }

  memset(packed_row, 0, required_bytes);
  uint16_t columns = TILE_RLE_INDEX_COLUMNS(width);
  size_t index_offset = (size_t)y * columns * TILE_RLE_ROW_INDEX_BYTES;
  size_t encoded_offset = row_index[index_offset] |
      ((size_t)row_index[index_offset + 1] << 8);
  uint8_t skip = row_index[index_offset + 2];
  uint16_t pixel = 0;
  while (encoded_offset < encoded_len && pixel < width) {
    uint8_t byte = encoded[encoded_offset++];
    uint16_t run_length = (byte >> 4) + 1;
    uint8_t palette_index = byte & 0x0f;
    if (skip >= run_length) {
      return false;
    }
    run_length -= skip;
    skip = 0;
    if (run_length > width - pixel) {
      run_length = width - pixel;
    }
    while (run_length-- > 0) {
      if (pixel & 1) {
        packed_row[pixel / 2] |= palette_index << 4;
      } else {
        packed_row[pixel / 2] = palette_index;
      }
      pixel++;
    }
  }
  return pixel == width;
}
