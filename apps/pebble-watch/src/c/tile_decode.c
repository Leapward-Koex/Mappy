#include "mappy.h"

// Inbound tile payload streaming, validation, and compressed-at-rest storage.

static int32_t s_tile_chunk_compression;

bool decode_cached_tile_row(const TileCacheEntry *entry, int row,
                            uint8_t *packed_row, size_t packed_row_bytes) {
  if (!entry || !entry->valid || !packed_row || row < 0 ||
      row >= s_tile_height) {
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
    // Every supported geometry has an even width, so packed rows are byte
    // aligned in the arena.
    memcpy(packed_row, stored + (size_t)row * required_bytes,
           required_bytes);
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

static void suppress_failed_tile(int32_t world_x, int32_t world_y, int8_t zoom) {
  suppress_tile_request(world_x, world_y, zoom);
}

static TileApplyResult reject_tile_chunk(TileFlight *flight, int8_t zoom,
                                         int32_t detail, const char *message,
                                         bool suppress) {
  int32_t world_x = flight ? flight->request.world_x : 0;
  int32_t world_y = flight ? flight->request.world_y : 0;
  reset_tile_chunk_assembly();
  if (suppress && flight) {
    suppress_failed_tile(world_x, world_y, zoom);
  }
  set_bottom_text(message);
  schedule_tile_redraw(true);
  send_log_event(3, zoom, detail, message);
  if (flight) {
    complete_tile_flight(flight);
  }
  return TileApplyRejected;
}

static bool tile_chunk_is_terminal(int32_t total_bytes, int32_t chunk_offset,
                                   uint16_t payload_len) {
  return total_bytes > 0 && chunk_offset >= 0 && payload_len > 0 &&
      (int64_t)chunk_offset + payload_len >= total_bytes;
}

static bool tile_i32_tuple(const Tuple *tuple) {
  return tuple && tuple->length == sizeof(int32_t) &&
      (tuple->type == TUPLE_INT ||
       (tuple->type == TUPLE_UINT && tuple->value->uint32 <= INT32_MAX));
}

TileApplyResult apply_tile(DictionaryIterator *iter) {
  Tuple *x_tuple = dict_find(iter, MESSAGE_KEY_world_x);
  Tuple *y_tuple = dict_find(iter, MESSAGE_KEY_world_y);
  Tuple *zoom_tuple = dict_find(iter, MESSAGE_KEY_tile_zoom);
  Tuple *width_tuple = dict_find(iter, MESSAGE_KEY_width);
  Tuple *height_tuple = dict_find(iter, MESSAGE_KEY_height);
  Tuple *total_tuple = dict_find(iter, MESSAGE_KEY_total_bytes);
  Tuple *chunk_index_tuple = dict_find(iter, MESSAGE_KEY_chunk_index);
  Tuple *chunk_offset_tuple = dict_find(iter, MESSAGE_KEY_chunk_offset);
  Tuple *data_tuple = dict_find(iter, MESSAGE_KEY_chunk_data);
  Tuple *format_tuple = dict_find(iter, MESSAGE_KEY_compression_format);
  Tuple *request_id_tuple = dict_find(iter, MESSAGE_KEY_request_id);
  // Identify an active assembly by request ID before trusting its new metadata.
  // This lets us reject a changed identity instead of treating it as a new tile.
  TileFlight *flight = NULL;
  if (tile_i32_tuple(request_id_tuple) && s_tile_chunk_active &&
      s_tile_chunk_request_id == request_id_tuple->value->int32) {
    flight = find_tile_flight(s_tile_chunk_world_x, s_tile_chunk_world_y,
                              s_tile_chunk_zoom, s_tile_chunk_request_id);
  }
  bool valid_identity = tile_i32_tuple(x_tuple) && tile_i32_tuple(y_tuple) &&
      tile_i32_tuple(zoom_tuple) && tile_i32_tuple(request_id_tuple) &&
      zoom_tuple->value->int32 >= MIN_MAP_ZOOM &&
      zoom_tuple->value->int32 <= MAX_MAP_ZOOM &&
      request_id_tuple->value->int32 > 0;
  if (!flight && valid_identity) {
    flight = find_tile_flight(x_tuple->value->int32, y_tuple->value->int32,
                              (int8_t)zoom_tuple->value->int32,
                              request_id_tuple->value->int32);
  }
  if (!valid_identity || !tile_i32_tuple(width_tuple) ||
      !tile_i32_tuple(height_tuple) || !tile_i32_tuple(total_tuple) ||
      !tile_i32_tuple(chunk_index_tuple) || !tile_i32_tuple(chunk_offset_tuple) ||
      !tile_i32_tuple(format_tuple) || !data_tuple ||
      data_tuple->type != TUPLE_BYTE_ARRAY) {
    if (flight) {
      return reject_tile_chunk(flight, flight->request.zoom, 0,
                               "tile missing data", false);
    }
    return TileApplyIgnored;
  }
  if (!flight) {
    return TileApplyIgnored;
  }

  int32_t world_x = x_tuple->value->int32;
  int32_t world_y = y_tuple->value->int32;
  int8_t zoom = (int8_t)zoom_tuple->value->int32;
  int width = width_tuple->value->int32;
  int height = height_tuple->value->int32;
  int32_t total_bytes = total_tuple->value->int32;
  int32_t compression = format_tuple->value->int32;
  int32_t chunk_index = chunk_index_tuple->value->int32;
  int32_t chunk_offset = chunk_offset_tuple->value->int32;
  uint16_t payload_len = data_tuple->length;
  int32_t request_id = request_id_tuple->value->int32;

  if (s_tile_chunk_active && s_tile_chunk_request_id == request_id &&
      (s_tile_chunk_world_x != world_x || s_tile_chunk_world_y != world_y ||
       s_tile_chunk_zoom != zoom || s_tile_chunk_width != width ||
       s_tile_chunk_height != height || s_tile_chunk_total != total_bytes ||
       s_tile_chunk_compression != compression)) {
    return reject_tile_chunk(flight, flight->request.zoom, compression,
                             "tile metadata changed", false);
  }

  if (!flight->discard_only &&
      !tile_coordinates_visible(world_x, world_y, zoom)) {
    flight->discard_only = true;
    if (s_tile_chunk_active && s_tile_chunk_request_id == request_id) {
      reset_tile_chunk_assembly();
    }
  }
  if (flight->discard_only) {
    if (tile_chunk_is_terminal(total_bytes, chunk_offset, payload_len)) {
      complete_tile_flight(flight);
    }
    return TileApplyDiscarded;
  }

  if (zoom < MIN_MAP_ZOOM || zoom > MAX_MAP_ZOOM ||
      width != s_tile_width || height != s_tile_height ||
      total_bytes <= 0 || total_bytes > s_tile_pixels ||
      payload_len == 0 || payload_len > MAX_TILE_ENCODED_BYTES ||
      compression < TileCompressionRle || compression > TileCompressionLz4Rle ||
      (compression == TileCompressionPacked && total_bytes != s_tile_bytes) ||
      chunk_index < 0 || chunk_offset < 0 ||
      (int64_t)chunk_offset + payload_len > total_bytes) {
    return reject_tile_chunk(flight, zoom, payload_len, "tile rejected",
                             false);
  }

  bool starts_new_tile = !s_tile_chunk_active ||
      s_tile_chunk_request_id != request_id;
  if (starts_new_tile) {
    if (chunk_index != 0 || chunk_offset != 0) {
      APP_LOG(APP_LOG_LEVEL_WARNING, "Tile chunk reject");
      return reject_tile_chunk(flight, zoom, payload_len,
                               "tile chunk rejected", false);
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
    s_tile_chunk_compression = compression;
    tile_performance_begin();
    int32_t index_bytes = TILE_RLE_INDEX_BYTES(s_tile_width, s_tile_height);
    s_tile_chunk_store_packed = compression == TileCompressionPacked ||
        compression == TileCompressionLz4Packed ||
        (compression == TileCompressionRle &&
         total_bytes + index_bytes >= s_tile_bytes);
    if (compression == TileCompressionRle && s_tile_chunk_store_packed) {
      tile_rle_stream_init(&s_tile_chunk_decoder.rle,
                           (uint32_t)s_tile_pixels, s_tile_decode_scratch,
                           (uint32_t)s_tile_bytes);
    } else if (compression == TileCompressionLz4Packed ||
               compression == TileCompressionLz4Rle) {
      uint32_t limit = compression == TileCompressionLz4Packed ?
          s_tile_bytes : s_tile_bytes - index_bytes - 1;
      tile_lz4_stream_init(&s_tile_chunk_decoder.lz4, limit);
    }
  }

  if (chunk_index != s_tile_chunk_next_index ||
      chunk_offset != s_tile_chunk_received) {
    APP_LOG(APP_LOG_LEVEL_WARNING, "Tile chunk reject");
    return reject_tile_chunk(flight, zoom, payload_len,
                             "tile chunk rejected", false);
  }

  const uint8_t *payload = data_tuple->value->data;
  uint32_t decode_started_ms = tile_performance_clock();
  bool accepted_chunk = false;
  if (compression == TileCompressionLz4Packed ||
      compression == TileCompressionLz4Rle) {
    accepted_chunk = tile_lz4_stream_feed(&s_tile_chunk_decoder.lz4,
                                          payload, payload_len,
                                          s_tile_decode_scratch);
  } else if (compression == TileCompressionRle && s_tile_chunk_store_packed) {
    accepted_chunk = tile_rle_stream_feed(&s_tile_chunk_decoder.rle, payload,
                                          payload_len,
                                          s_tile_decode_scratch);
  } else if ((int64_t)chunk_offset + payload_len <= s_tile_bytes) {
    memcpy(s_tile_decode_scratch + chunk_offset, payload, payload_len);
    accepted_chunk = true;
  }
  tile_performance_decode_end(decode_started_ms);
  if (!accepted_chunk) {
    APP_LOG(APP_LOG_LEVEL_WARNING, "Tile decode failed");
    return reject_tile_chunk(flight, zoom, payload_len,
                             "tile decode failed", true);
  }

  s_tile_chunk_received += payload_len;
  s_tile_chunk_next_index++;
  if (s_tile_chunk_received < total_bytes) {
    return TileApplyIncomplete;
  }

  decode_started_ms = tile_performance_clock();
  bool decoded_ok = false;
  int32_t stored_length = 0;
  int32_t encoded_length = compression == TileCompressionLz4Rle ?
      (int32_t)s_tile_chunk_decoder.lz4.output_bytes : total_bytes;
  TileStorageFormat storage_format = TileStorageNone;
  if (s_tile_chunk_store_packed) {
    decoded_ok = compression == TileCompressionPacked ||
        (compression == TileCompressionRle &&
         tile_rle_stream_finish(&s_tile_chunk_decoder.rle)) ||
        (compression == TileCompressionLz4Packed &&
         tile_lz4_stream_finish(&s_tile_chunk_decoder.lz4) &&
         s_tile_chunk_decoder.lz4.output_bytes == (uint32_t)s_tile_bytes);
    stored_length = s_tile_bytes;
    storage_format = TileStoragePacked;
  } else {
    size_t row_index_bytes = TILE_RLE_INDEX_BYTES(s_tile_width,
                                                  s_tile_height);
    stored_length = encoded_length + (int32_t)row_index_bytes;
    uint8_t *row_index = stored_length <= MAX_TILE_BYTES ?
        s_tile_decode_scratch + encoded_length : NULL;
    // Building the index walks every run and verifies the exact decoded pixel
    // count, so a separate full decode into the shared scratch buffer would
    // only repeat the same validation work.
    decoded_ok = row_index &&
        (compression != TileCompressionLz4Rle ||
         tile_lz4_stream_finish(&s_tile_chunk_decoder.lz4)) &&
        tile_rle_build_row_index(s_tile_decode_scratch, encoded_length,
                                 (uint16_t)s_tile_width,
                                 (uint16_t)s_tile_height, row_index,
                                 row_index_bytes);
    storage_format = TileStorageIndexedRle;
  }
  tile_performance_decode_end(decode_started_ms);
  if (!decoded_ok) {
    APP_LOG(APP_LOG_LEVEL_WARNING, "Tile decode failed");
    return reject_tile_chunk(flight, zoom, total_bytes,
                             "tile decode failed", true);
  }

  // Re-check after full validation and before any cache allocation. Touch and
  // viewport changes mark the flight discard-only, so stale work never evicts
  // useful tiles or compacts the arena.
  if (flight->discard_only ||
      !tile_coordinates_visible(world_x, world_y, zoom)) {
    reset_tile_chunk_assembly();
    complete_tile_flight(flight);
    return TileApplyCompletedOffscreen;
  }

  TileCacheEntry *entry = allocate_tile_slot_with_diagnostics(
      world_x, world_y, zoom, NULL);
  if (!entry || !reserve_tile_storage(entry, (uint16_t)stored_length,
                                      storage_format)) {
    if (entry) {
      entry->valid = false;
      entry->storage_suppressed = true;
    }
    return reject_tile_chunk(flight, zoom, stored_length,
                             "tile cache unavailable", entry == NULL);
  }

  uint8_t *stored = tile_storage_mutable_data(&s_tile_storage_arena,
                                              &entry->storage);
  if (!stored) {
    return reject_tile_chunk(flight, zoom, stored_length,
                             "tile cache unavailable", true);
  }
  memcpy(stored, s_tile_decode_scratch, stored_length);
  entry->world_x = world_x;
  entry->world_y = world_y;
  entry->zoom = zoom;
  entry->valid = true;
  entry->storage_suppressed = false;
  entry->encoded_length = storage_format == TileStoragePacked ?
      0 : (uint16_t)encoded_length;
  entry->last_used = ++s_access_counter;
  tile_performance_accepted(flight, entry, compression, total_bytes);
  bool render_visible = tile_is_visible(entry);
  bool tile_animated = start_tile_animation(entry, true);
  reset_tile_chunk_assembly();
  APP_LOG(APP_LOG_LEVEL_DEBUG,
          "Tile accept x=%ld y=%ld z=%d encoded=%ld",
          (long)world_x, (long)world_y, (int)zoom, (long)total_bytes);
  int visible_count = render_visible ? valid_visible_tile_count() : 0;
  bool grid_complete = false;
  if (render_visible) {
    zoom_fallback_maybe_finish();
    update_state_after_map_change();
    grid_complete = visible_grid_is_complete();
  }
#ifdef MAPPY_WATCH_PHONE_MODE_FIXTURE
  if (grid_complete) {
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_GRID");
  }
#endif
  bool flush_redraw = visible_count == 1 || grid_complete;
  complete_tile_flight(flight);
  if (render_visible && !tile_animated) {
    schedule_tile_redraw(flush_redraw);
  }
  return TileApplyCompletedVisible;
}
