#include "mappy.h"

// Inbound tile payload streaming, validation, and compressed-at-rest storage.

bool decode_tile_rle(const uint8_t *encoded, uint16_t encoded_len,
                     uint8_t *decoded) {
  return encoded && encoded_len > 0 && encoded_len <= s_tile_pixels &&
      tile_rle_decode(encoded, encoded_len, (uint32_t)s_tile_pixels, decoded,
                      (uint32_t)s_tile_bytes);
}

bool decode_cached_tile(const TileCacheEntry *entry, uint8_t *decoded) {
  if (!entry || !entry->valid || !decoded ||
      !tile_storage_ref_valid(&entry->storage)) {
    return false;
  }
  // High-entropy multi-chunk tiles stream into the shared scratch buffer.
  // Do not let an intervening redraw overwrite that in-progress decode.
  if (s_tile_chunk_active && s_tile_chunk_store_packed &&
      decoded == s_tile_decode_scratch) {
    return false;
  }
  const uint8_t *stored = tile_storage_data(&s_tile_storage_arena,
                                            &entry->storage);
  if (!stored) {
    return false;
  }
  if (entry->storage.format == TileStoragePacked) {
    if (entry->storage.length != s_tile_bytes) {
      return false;
    }
    memcpy(decoded, stored, s_tile_bytes);
    return true;
  }
  if (entry->storage.format == TileStorageIndexedRle &&
      entry->encoded_length > 0 &&
      entry->encoded_length < entry->storage.length) {
    return decode_tile_rle(stored, entry->encoded_length, decoded);
  }
  return false;
}

bool sample_cached_tile_palette_index(const TileCacheEntry *entry, int local_x,
                                      int local_y, uint8_t *palette_index) {
  if (!entry || !entry->valid || !palette_index || local_x < 0 || local_y < 0 ||
      local_x >= s_tile_width || local_y >= s_tile_height) {
    return false;
  }
  const uint8_t *stored = tile_storage_data(&s_tile_storage_arena,
                                            &entry->storage);
  if (!stored) {
    return false;
  }
  if (entry->storage.format == TileStoragePacked) {
    int pixel_index = local_y * s_tile_width + local_x;
    uint8_t packed = stored[pixel_index / 2];
    *palette_index = (pixel_index & 1) ? packed >> 4 : packed & 0x0f;
    return true;
  }
  if (entry->storage.format != TileStorageIndexedRle ||
      entry->encoded_length == 0 ||
      entry->encoded_length >= entry->storage.length) {
    return false;
  }
  const uint8_t *row_index = stored + entry->encoded_length;
  size_t row_index_bytes = entry->storage.length - entry->encoded_length;
  return tile_rle_sample_indexed(stored, entry->encoded_length, row_index,
                                 row_index_bytes, (uint16_t)s_tile_width,
                                 (uint16_t)s_tile_height, (uint16_t)local_x,
                                 (uint16_t)local_y, palette_index);
}

bool decode_cached_tile_row(const TileCacheEntry *entry, int row,
                            uint8_t *packed_row, size_t packed_row_bytes) {
  if (!entry || !entry->valid || !packed_row || row < 0 ||
      row >= s_tile_height ||
      (s_tile_chunk_active && s_tile_chunk_store_packed)) {
    return false;
  }
  size_t required_bytes = ((size_t)s_tile_width + 1) / 2;
  if (packed_row_bytes < required_bytes) {
    return false;
  }
  const uint8_t *stored = tile_storage_data(&s_tile_storage_arena,
                                            &entry->storage);
  if (!stored) {
    return false;
  }
  if (entry->storage.format == TileStoragePacked) {
    if ((s_tile_width & 1) == 0) {
      memcpy(packed_row, stored + (size_t)row * required_bytes,
             required_bytes);
      return true;
    }
    memset(packed_row, 0, required_bytes);
    int first_pixel = row * s_tile_width;
    for (int x = 0; x < s_tile_width; x++) {
      int source_pixel = first_pixel + x;
      uint8_t source = stored[source_pixel / 2];
      uint8_t value = (source_pixel & 1) ? source >> 4 : source & 0x0f;
      if (x & 1) {
        packed_row[x / 2] |= value << 4;
      } else {
        packed_row[x / 2] = value;
      }
    }
    return true;
  }
  if (entry->storage.format != TileStorageIndexedRle ||
      entry->encoded_length == 0 ||
      entry->encoded_length >= entry->storage.length) {
    return false;
  }
  return tile_rle_decode_indexed_row(
      stored, entry->encoded_length, stored + entry->encoded_length,
      entry->storage.length - entry->encoded_length,
      (uint16_t)s_tile_width, (uint16_t)s_tile_height, (uint16_t)row,
      packed_row, packed_row_bytes);
}

static void reject_tile_chunk(TileCacheEntry *entry, int8_t zoom,
                              int32_t detail, const char *message) {
  reset_tile_chunk_assembly();
  if (entry) {
    entry->valid = false;
    entry->storage_suppressed =
        strcmp(message, "tile decode failed") == 0 ||
        strcmp(message, "tile cache unavailable") == 0;
    clear_tile_pending(entry);
    entry->animation_active = false;
    entry->animation_mode = TILE_ANIMATION_NONE;
  }
  set_bottom_text(message);
  send_log_event(3, zoom, detail, message);
  send_next_tile_request();
}

void apply_tile(DictionaryIterator *iter) {
  Tuple *x_tuple = dict_find(iter, MESSAGE_KEY_world_x);
  Tuple *y_tuple = dict_find(iter, MESSAGE_KEY_world_y);
  Tuple *zoom_tuple = dict_find(iter, MESSAGE_KEY_tile_zoom);
  Tuple *width_tuple = dict_find(iter, MESSAGE_KEY_width);
  Tuple *height_tuple = dict_find(iter, MESSAGE_KEY_height);
  Tuple *total_tuple = dict_find(iter, MESSAGE_KEY_total_bytes);
  Tuple *chunk_index_tuple = dict_find(iter, MESSAGE_KEY_chunk_index);
  Tuple *chunk_offset_tuple = dict_find(iter, MESSAGE_KEY_chunk_offset);
  Tuple *data_tuple = dict_find(iter, MESSAGE_KEY_chunk_data);
  Tuple *request_id_tuple = dict_find(iter, MESSAGE_KEY_request_id);
  if (!x_tuple || !y_tuple || !zoom_tuple || !total_tuple || !data_tuple ||
      !request_id_tuple) {
    set_bottom_text("Tile missing data");
    return;
  }

  int32_t world_x = x_tuple->value->int32;
  int32_t world_y = y_tuple->value->int32;
  int8_t zoom = zoom_tuple->value->int32;
  int width = width_tuple ? width_tuple->value->int32 : s_tile_width;
  int height = height_tuple ? height_tuple->value->int32 : s_tile_height;
  int32_t total_bytes = total_tuple->value->int32;
  int32_t chunk_index = chunk_index_tuple ? chunk_index_tuple->value->int32 : 0;
  int32_t chunk_offset = chunk_offset_tuple ? chunk_offset_tuple->value->int32 : 0;
  uint16_t payload_len = data_tuple->length;
  int32_t request_id = request_id_tuple->value->int32;
  if (zoom < MIN_MAP_ZOOM || zoom > MAX_MAP_ZOOM ||
      width != s_tile_width || height != s_tile_height ||
      total_bytes <= 0 || total_bytes > s_tile_pixels ||
      payload_len == 0 || payload_len > MAX_RLE_BYTES ||
      chunk_index < 0 || chunk_offset < 0 ||
      chunk_offset + payload_len > total_bytes) {
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Tile rejected x=%ld y=%ld z=%d msg=%dx%d active=%dx%d total=%ld payload=%u chunk=%ld offset=%ld cache=%d",
            (long)world_x, (long)world_y, (int)zoom, width, height,
            s_tile_width, s_tile_height, (long)total_bytes, payload_len,
            (long)chunk_index, (long)chunk_offset, active_tile_cache_size());
    TileCacheEntry *failed = find_tile(world_x, world_y, zoom);
    reject_tile_chunk(failed, zoom, payload_len, "tile rejected");
    return;
  }

  TileCacheEntry *entry = find_tile(world_x, world_y, zoom);
  if (!entry || !entry->pending || request_id <= 0 ||
      entry->pending_request_id != request_id) {
    APP_LOG(APP_LOG_LEVEL_DEBUG,
            "Tile ignore x=%ld y=%ld z=%d request=%ld expected=%ld reason=staleRequest",
            (long)world_x, (long)world_y, (int)zoom, (long)request_id,
            (long)(entry ? entry->pending_request_id : 0));
    send_next_tile_request();
    return;
  }

  bool starts_new_tile = !s_tile_chunk_active ||
      s_tile_chunk_world_x != world_x ||
      s_tile_chunk_world_y != world_y ||
      s_tile_chunk_zoom != zoom ||
      s_tile_chunk_width != width ||
      s_tile_chunk_height != height ||
      s_tile_chunk_total != total_bytes ||
      s_tile_chunk_request_id != request_id;
  if (starts_new_tile) {
    if (chunk_index != 0 || chunk_offset != 0) {
      APP_LOG(APP_LOG_LEVEL_WARNING,
              "Tile chunk reject x=%ld y=%ld z=%d reason=startMismatch chunk=%ld offset=%ld total=%ld payload=%u",
              (long)world_x, (long)world_y, (int)zoom, (long)chunk_index,
              (long)chunk_offset, (long)total_bytes, payload_len);
      reject_tile_chunk(entry, zoom, payload_len, "tile chunk rejected");
      return;
    }
    reset_tile_chunk_assembly();
    s_tile_chunk_active = true;
    s_tile_chunk_world_x = world_x;
    s_tile_chunk_world_y = world_y;
    s_tile_chunk_zoom = zoom;
    s_tile_chunk_width = width;
    s_tile_chunk_height = height;
    s_tile_chunk_total = total_bytes;
    s_tile_chunk_request_id = request_id;
    int32_t indexed_bytes = total_bytes +
        TILE_RLE_INDEX_BYTES(s_tile_width, s_tile_height);
    s_tile_chunk_store_packed = indexed_bytes >= s_tile_bytes;
    if (s_tile_chunk_store_packed) {
      tile_rle_stream_init(&s_tile_chunk_decoder, (uint32_t)s_tile_pixels,
                           s_tile_decode_scratch, (uint32_t)s_tile_bytes);
    } else if (!reserve_tile_storage(entry, (uint16_t)indexed_bytes,
                                     TileStorageIndexedRle)) {
      APP_LOG(APP_LOG_LEVEL_ERROR,
              "Tile storage reserve failed x=%ld y=%ld z=%d stored=%ld used=%u/%u",
              (long)world_x, (long)world_y, (int)zoom, (long)total_bytes,
              (unsigned)s_tile_storage_arena.used,
              (unsigned)s_tile_storage_arena.capacity);
      reject_tile_chunk(entry, zoom, total_bytes, "tile cache unavailable");
      return;
    }
  }

  if (chunk_index != s_tile_chunk_next_index ||
      chunk_offset != s_tile_chunk_received) {
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Tile chunk reject x=%ld y=%ld z=%d reason=sequence expected_chunk=%ld expected_offset=%ld chunk=%ld offset=%ld total=%ld",
            (long)world_x, (long)world_y, (int)zoom,
            (long)s_tile_chunk_next_index, (long)s_tile_chunk_received,
            (long)chunk_index, (long)chunk_offset, (long)total_bytes);
    reject_tile_chunk(entry, zoom, payload_len, "tile chunk rejected");
    return;
  }

  const uint8_t *payload = data_tuple->value->data;
  bool accepted_chunk = false;
  if (s_tile_chunk_store_packed) {
    accepted_chunk = tile_rle_stream_feed(&s_tile_chunk_decoder, payload,
                                          payload_len,
                                          s_tile_decode_scratch);
  } else {
    uint8_t *stored = tile_storage_mutable_data(&s_tile_storage_arena,
                                                &entry->storage);
    if (stored) {
      memcpy(stored + chunk_offset, payload, payload_len);
      accepted_chunk = true;
    }
  }
  if (!accepted_chunk) {
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Tile chunk decode failed x=%ld y=%ld z=%d chunk=%ld payload=%u",
            (long)world_x, (long)world_y, (int)zoom, (long)chunk_index,
            payload_len);
    reject_tile_chunk(entry, zoom, payload_len, "tile decode failed");
    return;
  }

  s_tile_chunk_received += payload_len;
  s_tile_chunk_next_index++;
  if (s_tile_chunk_received < total_bytes) {
    return;
  }

  bool decoded_ok = false;
  if (s_tile_chunk_store_packed) {
    decoded_ok = tile_rle_stream_finish(&s_tile_chunk_decoder);
    if (decoded_ok) {
      decoded_ok = reserve_tile_storage(entry, (uint16_t)s_tile_bytes,
                                        TileStoragePacked);
    }
    if (decoded_ok) {
      uint8_t *stored = tile_storage_mutable_data(&s_tile_storage_arena,
                                                  &entry->storage);
      decoded_ok = stored != NULL;
      if (stored) {
        memcpy(stored, s_tile_decode_scratch, s_tile_bytes);
      }
    }
  } else {
    const uint8_t *stored = tile_storage_data(&s_tile_storage_arena,
                                              &entry->storage);
    entry->encoded_length = (uint16_t)total_bytes;
    uint8_t *row_index = stored ?
        (uint8_t *)stored + entry->encoded_length : NULL;
    size_t row_index_bytes = entry->storage.length - entry->encoded_length;
    decoded_ok = stored &&
        decode_tile_rle(stored, entry->encoded_length,
                        s_tile_decode_scratch) &&
        tile_rle_build_row_index(stored, entry->encoded_length,
                                 (uint16_t)s_tile_width,
                                 (uint16_t)s_tile_height, row_index,
                                 row_index_bytes);
  }
  if (!decoded_ok) {
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Tile decode failed x=%ld y=%ld z=%d bytes=%ld format=%s",
            (long)world_x, (long)world_y, (int)zoom, (long)total_bytes,
            s_tile_chunk_store_packed ? "packed" : "rle");
    reject_tile_chunk(entry, zoom, total_bytes, "tile decode failed");
    return;
  }

  bool was_pending = entry->pending;
  entry->world_x = world_x;
  entry->world_y = world_y;
  entry->zoom = zoom;
  entry->valid = true;
  entry->storage_suppressed = false;
  if (entry->storage.format == TileStoragePacked) {
    entry->encoded_length = 0;
  }
  clear_tile_pending(entry);
  entry->last_used = ++s_access_counter;
  start_tile_animation(entry, was_pending);
  const char *format = entry->storage.format == TileStoragePacked ?
      "packed" : "indexed-rle";
  uint16_t stored_bytes = entry->storage.length;
  reset_tile_chunk_assembly();
  APP_LOG(APP_LOG_LEVEL_DEBUG,
          "Tile accept x=%ld y=%ld z=%d encoded=%ld stored=%u format=%s visible=%d arena=%u/%u cache=%d/%d",
          (long)world_x, (long)world_y, (int)zoom, (long)total_bytes,
          (unsigned)stored_bytes, format, tile_is_visible(entry) ? 1 : 0,
          (unsigned)s_tile_storage_arena.used,
          (unsigned)s_tile_storage_arena.capacity,
          active_tile_cache_size(), TILE_CACHE_SIZE);
  int visible_count = valid_visible_tile_count();
  if (visible_count == 1 || !visible_grid_has_missing_tiles()) {
    APP_LOG(APP_LOG_LEVEL_INFO,
            "Mappy storage heap=%u arena=%u/%u tiles=%d",
            (unsigned)heap_bytes_free(), (unsigned)s_tile_storage_arena.used,
            (unsigned)s_tile_storage_arena.capacity, visible_count);
  }
  update_state_after_map_change();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  send_next_tile_request();
}
