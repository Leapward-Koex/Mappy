#include "tile_storage.h"

#include <string.h>

void tile_storage_ref_reset(TileStorageRef *ref) {
  if (!ref) {
    return;
  }
  ref->offset = TILE_STORAGE_INVALID_OFFSET;
  ref->length = 0;
  ref->format = TileStorageNone;
}

bool tile_storage_ref_valid(const TileStorageRef *ref) {
  return ref && ref->offset != TILE_STORAGE_INVALID_OFFSET &&
      ref->length > 0 && ref->format != TileStorageNone;
}

void tile_storage_arena_init(TileStorageArena *arena, uint8_t *bytes,
                             uint16_t capacity) {
  if (!arena) {
    return;
  }
  arena->bytes = bytes;
  arena->capacity = capacity;
  arena->used = 0;
}

void tile_storage_arena_reset(TileStorageArena *arena) {
  if (arena) {
    arena->used = 0;
  }
}

void tile_storage_arena_remove(TileStorageArena *arena, TileStorageRef *target,
                               TileStorageRef *refs, size_t ref_count,
                               size_t ref_stride) {
  if (!arena || !arena->bytes || !tile_storage_ref_valid(target) ||
      target->offset + target->length > arena->used) {
    tile_storage_ref_reset(target);
    return;
  }

  uint16_t removed_offset = target->offset;
  uint16_t removed_length = target->length;
  uint16_t tail_offset = removed_offset + removed_length;
  uint16_t tail_length = arena->used - tail_offset;
  if (tail_length > 0) {
    memmove(arena->bytes + removed_offset, arena->bytes + tail_offset,
            tail_length);
  }
  arena->used -= removed_length;

  if (refs && ref_stride >= sizeof(TileStorageRef)) {
    for (size_t i = 0; i < ref_count; i++) {
      TileStorageRef *ref = (TileStorageRef *)((uint8_t *)refs +
                                               (i * ref_stride));
      if (ref != target && tile_storage_ref_valid(ref) &&
          ref->offset > removed_offset) {
        ref->offset -= removed_length;
      }
    }
  }
  tile_storage_ref_reset(target);
}

bool tile_storage_arena_reserve(TileStorageArena *arena, TileStorageRef *target,
                                uint16_t length, TileStorageFormat format) {
  if (!arena || !arena->bytes || !target || length == 0 ||
      format == TileStorageNone || tile_storage_ref_valid(target) ||
      length > arena->capacity - arena->used) {
    return false;
  }
  target->offset = arena->used;
  target->length = length;
  target->format = (uint8_t)format;
  arena->used += length;
  return true;
}

uint8_t *tile_storage_mutable_data(TileStorageArena *arena,
                                   const TileStorageRef *ref) {
  if (!arena || !arena->bytes || !tile_storage_ref_valid(ref) ||
      ref->offset + ref->length > arena->used) {
    return NULL;
  }
  return arena->bytes + ref->offset;
}

const uint8_t *tile_storage_data(const TileStorageArena *arena,
                                 const TileStorageRef *ref) {
  return tile_storage_mutable_data((TileStorageArena *)arena, ref);
}

int tile_storage_select_eviction(
    const TileStorageEvictionCandidate *candidates, size_t candidate_count) {
  if (!candidates) {
    return -1;
  }
  int oldest_offscreen = -1;
  int oldest_visible = -1;
  uint32_t offscreen_access = UINT32_MAX;
  uint32_t visible_access = UINT32_MAX;
  for (size_t i = 0; i < candidate_count; i++) {
    const TileStorageEvictionCandidate *candidate = &candidates[i];
    if (!candidate->eligible) {
      continue;
    }
    if (!candidate->visible && candidate->last_used < offscreen_access) {
      offscreen_access = candidate->last_used;
      oldest_offscreen = (int)i;
    } else if (candidate->visible && candidate->last_used < visible_access) {
      visible_access = candidate->last_used;
      oldest_visible = (int)i;
    }
  }
  return oldest_offscreen >= 0 ? oldest_offscreen : oldest_visible;
}
