#include "mappy.h"

// Inbound tile payload streaming, validation, and compressed-at-rest storage.

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
  Tuple *request_id_tuple = dict_find(iter, MESSAGE_KEY_request_id);
  if (!x_tuple || !y_tuple || !zoom_tuple || !total_tuple || !data_tuple ||
      !request_id_tuple) {
    set_bottom_text("Tile missing data");
    schedule_tile_redraw(true);
    return TileApplyIgnored;
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
  TileFlight *flight = find_tile_flight(world_x, world_y, zoom, request_id);
  if (!flight || request_id <= 0) {
    return TileApplyIgnored;
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
      payload_len == 0 || payload_len > MAX_RLE_BYTES ||
      chunk_index < 0 || chunk_offset < 0 ||
      chunk_offset + payload_len > total_bytes) {
    return reject_tile_chunk(flight, zoom, payload_len, "tile rejected",
                             false);
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
    int32_t indexed_bytes = total_bytes +
        TILE_RLE_INDEX_BYTES(s_tile_width, s_tile_height);
    s_tile_chunk_store_packed = indexed_bytes >= s_tile_bytes;
    if (s_tile_chunk_store_packed) {
      tile_rle_stream_init(&s_tile_chunk_decoder, (uint32_t)s_tile_pixels,
                           s_tile_decode_scratch, (uint32_t)s_tile_bytes);
    }
  }

  if (chunk_index != s_tile_chunk_next_index ||
      chunk_offset != s_tile_chunk_received) {
    APP_LOG(APP_LOG_LEVEL_WARNING, "Tile chunk reject");
    return reject_tile_chunk(flight, zoom, payload_len,
                             "tile chunk rejected", false);
  }

  const uint8_t *payload = data_tuple->value->data;
  bool accepted_chunk = false;
  if (s_tile_chunk_store_packed) {
    accepted_chunk = tile_rle_stream_feed(&s_tile_chunk_decoder, payload,
                                          payload_len,
                                          s_tile_decode_scratch);
  } else {
    int32_t indexed_bytes = total_bytes +
        TILE_RLE_INDEX_BYTES(s_tile_width, s_tile_height);
    if (indexed_bytes <= MAX_TILE_BYTES) {
      memcpy(s_tile_decode_scratch + chunk_offset, payload, payload_len);
      accepted_chunk = true;
    }
  }
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

  bool decoded_ok = false;
  int32_t stored_length = 0;
  TileStorageFormat storage_format = TileStorageNone;
  if (s_tile_chunk_store_packed) {
    decoded_ok = tile_rle_stream_finish(&s_tile_chunk_decoder);
    stored_length = s_tile_bytes;
    storage_format = TileStoragePacked;
  } else {
    size_t row_index_bytes = TILE_RLE_INDEX_BYTES(s_tile_width,
                                                  s_tile_height);
    stored_length = total_bytes + (int32_t)row_index_bytes;
    uint8_t *row_index = stored_length <= MAX_TILE_BYTES ?
        s_tile_decode_scratch + total_bytes : NULL;
    // Building the index walks every run and verifies the exact decoded pixel
    // count, so a separate full decode into the shared scratch buffer would
    // only repeat the same validation work.
    decoded_ok = row_index &&
        tile_rle_build_row_index(s_tile_decode_scratch, total_bytes,
                                 (uint16_t)s_tile_width,
                                 (uint16_t)s_tile_height, row_index,
                                 row_index_bytes);
    storage_format = TileStorageIndexedRle;
  }
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
      0 : (uint16_t)total_bytes;
  entry->last_used = ++s_access_counter;
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
