#include "mappy.h"

// Inbound tile payload assembly, validation, and RLE decode.

bool decode_tile_rle(const uint8_t *encoded, uint16_t encoded_len, uint8_t *decoded) {
  if (!encoded || !decoded || encoded_len == 0 || encoded_len > s_tile_pixels) {
    return false;
  }

  memset(decoded, 0, s_tile_bytes);
  int pixel_index = 0;
  for (uint16_t i = 0; i < encoded_len; i++) {
    int run_length = (encoded[i] >> 4) + 1;
    uint8_t palette_index = encoded[i] & 0x0f;
    if (pixel_index + run_length > s_tile_pixels) {
      return false;
    }

    if ((pixel_index & 1) && run_length > 0) {
      decoded[pixel_index / 2] |= palette_index << 4;
      pixel_index++;
      run_length--;
    }

    uint8_t packed_pair = palette_index | (palette_index << 4);
    while (run_length >= 2) {
      decoded[pixel_index / 2] = packed_pair;
      pixel_index += 2;
      run_length -= 2;
    }

    if (run_length > 0) {
      decoded[pixel_index / 2] = palette_index;
      pixel_index++;
    }
  }

  return pixel_index == s_tile_pixels;
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
    set_bottom_text("Tile rejected");
    send_log_event(3, zoom, payload_len, "tile rejected");
    TileCacheEntry *failed = find_tile(world_x, world_y, zoom);
    if (failed) {
      clear_tile_pending(failed);
      failed->animation_active = false;
      failed->animation_mode = TILE_ANIMATION_NONE;
    }
    send_next_tile_request();
    return;
  }

  TileCacheEntry *pending_entry = find_tile(world_x, world_y, zoom);
  if (!pending_entry || !pending_entry->pending || request_id <= 0 ||
      pending_entry->pending_request_id != request_id) {
    APP_LOG(APP_LOG_LEVEL_DEBUG,
            "Tile ignore x=%ld y=%ld z=%d request=%ld expected=%ld reason=staleRequest",
            (long)world_x, (long)world_y, (int)zoom, (long)request_id,
            (long)(pending_entry ? pending_entry->pending_request_id : 0));
    send_next_tile_request();
    return;
  }
  if (!pending_entry && !tile_coordinates_visible(world_x, world_y, zoom)) {
    APP_LOG(APP_LOG_LEVEL_DEBUG,
            "Tile ignore x=%ld y=%ld z=%d reason=notPendingNotVisible total=%ld payload=%u",
            (long)world_x, (long)world_y, (int)zoom, (long)total_bytes,
            payload_len);
    send_next_tile_request();
    return;
  }

  const uint8_t *payload = data_tuple->value->data;
  uint16_t assembled_len = payload_len;
  if (total_bytes != payload_len || chunk_offset != 0 || chunk_index != 0) {
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
        set_bottom_text("Tile chunk rejected");
        send_log_event(3, zoom, payload_len, "tile chunk rejected");
        send_next_tile_request();
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
      if (!ensure_tile_chunk_buffer(total_bytes)) {
        reset_tile_chunk_assembly();
        APP_LOG(APP_LOG_LEVEL_ERROR,
                "Tile chunk buffer allocation failed x=%ld y=%ld z=%d total=%ld",
                (long)world_x, (long)world_y, (int)zoom, (long)total_bytes);
        set_bottom_text("Tile chunk unavailable");
        send_log_event(3, zoom, total_bytes, "tile chunk unavailable");
        send_next_tile_request();
        return;
      }
    }

    if (chunk_index != s_tile_chunk_next_index ||
        chunk_offset != s_tile_chunk_received) {
      int32_t expected_chunk = s_tile_chunk_next_index;
      int32_t expected_offset = s_tile_chunk_received;
      APP_LOG(APP_LOG_LEVEL_WARNING,
              "Tile chunk reject x=%ld y=%ld z=%d reason=sequence expected_chunk=%ld expected_offset=%ld chunk=%ld offset=%ld total=%ld",
              (long)world_x, (long)world_y, (int)zoom,
              (long)expected_chunk, (long)expected_offset,
              (long)chunk_index, (long)chunk_offset, (long)total_bytes);
      reset_tile_chunk_assembly();
      set_bottom_text("Tile chunk rejected");
      send_log_event(3, zoom, payload_len, "tile chunk rejected");
      send_next_tile_request();
      return;
    }

    memcpy(s_tile_chunk_buffer + chunk_offset, payload, payload_len);
    s_tile_chunk_received += payload_len;
    s_tile_chunk_next_index++;
    if (s_tile_chunk_received < total_bytes) {
      return;
    }
    payload = s_tile_chunk_buffer;
    assembled_len = (uint16_t)total_bytes;
  }

  bool was_pending = pending_entry && pending_entry->pending;
  TileSlotDiagnostics slot_diag;
  TileCacheEntry *entry = allocate_tile_slot_with_diagnostics(world_x, world_y, zoom,
                                                              &slot_diag);
  if (!entry || !entry->decoded) {
    APP_LOG(APP_LOG_LEVEL_ERROR,
            "Tile apply failed x=%ld y=%ld z=%d reason=cacheUnavailable slot=%s",
            (long)world_x, (long)world_y, (int)zoom, slot_diag.reason);
    set_bottom_text("Tile cache unavailable");
    send_log_event(3, zoom, payload_len, "tile cache unavailable");
    send_next_tile_request();
    return;
  }
  if (!decode_tile_rle(payload, assembled_len, entry->decoded)) {
    APP_LOG(APP_LOG_LEVEL_WARNING,
            "Tile decode failed x=%ld y=%ld z=%d bytes=%u pending=%d slot=%s",
            (long)world_x, (long)world_y, (int)zoom, assembled_len,
            was_pending ? 1 : 0, slot_diag.reason);
    entry->valid = false;
    clear_tile_pending(entry);
    entry->animation_active = false;
    entry->animation_mode = TILE_ANIMATION_NONE;
    set_bottom_text("Tile decode failed");
    send_log_event(3, zoom, payload_len, "tile decode failed");
    send_next_tile_request();
    return;
  }
  reset_tile_chunk_assembly();

  entry->world_x = world_x;
  entry->world_y = world_y;
  entry->zoom = zoom;
  entry->valid = true;
  clear_tile_pending(entry);
  entry->last_used = ++s_access_counter;
  start_tile_animation(entry, was_pending);
  APP_LOG(APP_LOG_LEVEL_DEBUG,
          "Tile accept x=%ld y=%ld z=%d bytes=%u pending=%d visible=%d slot=%s old=%ld,%ld,%d oldv=%d oldp=%d cache=%d/%d",
          (long)world_x, (long)world_y, (int)zoom, assembled_len,
          was_pending ? 1 : 0, tile_is_visible(entry) ? 1 : 0,
          slot_diag.reason, (long)slot_diag.old_world_x,
          (long)slot_diag.old_world_y, (int)slot_diag.old_zoom,
          slot_diag.old_valid ? 1 : 0, slot_diag.old_pending ? 1 : 0,
          active_tile_cache_size(), TILE_CACHE_SIZE);
  update_state_after_map_change();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  send_next_tile_request();
}
