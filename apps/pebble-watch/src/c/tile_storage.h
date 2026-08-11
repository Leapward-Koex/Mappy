#ifndef MAPPY_TILE_STORAGE_H
#define MAPPY_TILE_STORAGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TILE_STORAGE_INVALID_OFFSET UINT16_MAX

typedef enum {
  TileStorageNone = 0,
  TileStorageIndexedRle = 1,
  TileStoragePacked = 2,
} TileStorageFormat;

typedef struct {
  uint16_t offset;
  uint16_t length;
  uint8_t format;
} TileStorageRef;

typedef struct {
  uint8_t *bytes;
  uint16_t capacity;
  uint16_t used;
} TileStorageArena;

typedef struct {
  bool eligible;
  bool visible;
  uint32_t last_used;
} TileStorageEvictionCandidate;

void tile_storage_ref_reset(TileStorageRef *ref);
bool tile_storage_ref_valid(const TileStorageRef *ref);
void tile_storage_arena_init(TileStorageArena *arena, uint8_t *bytes,
                             uint16_t capacity);
void tile_storage_arena_reset(TileStorageArena *arena);
void tile_storage_arena_remove(TileStorageArena *arena, TileStorageRef *target,
                               TileStorageRef *refs, size_t ref_count,
                               size_t ref_stride);
bool tile_storage_arena_reserve(TileStorageArena *arena, TileStorageRef *target,
                                uint16_t length, TileStorageFormat format);
uint8_t *tile_storage_mutable_data(TileStorageArena *arena,
                                   const TileStorageRef *ref);
const uint8_t *tile_storage_data(const TileStorageArena *arena,
                                 const TileStorageRef *ref);
int tile_storage_select_eviction(
    const TileStorageEvictionCandidate *candidates, size_t candidate_count);

#endif
