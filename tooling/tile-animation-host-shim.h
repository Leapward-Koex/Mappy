#ifndef MAPPY_TILE_ANIMATION_HOST_SHIM_H
#define MAPPY_TILE_ANIMATION_HOST_SHIM_H

#include <stdbool.h>
#include <stdint.h>
#include <time.h>

#define TILE_CACHE_SIZE 3

#define TILE_ANIMATION_NONE 0
#define TILE_ANIMATION_FADE 1
#define TILE_ANIMATION_FADE_ZOOM 2
#define TILE_ANIMATION_FADE_MS 180
#define TILE_ANIMATION_FADE_ZOOM_MS 220
#define TILE_ANIMATION_MAX_ACTIVE 2

typedef struct AppTimer {
  int unused;
} AppTimer;

typedef struct {
  int32_t world_x;
  int32_t world_y;
  int8_t zoom;
  bool valid;
  bool animation_active;
  uint8_t animation_mode;
  time_t animation_started_s;
  uint16_t animation_started_ms;
} TileCacheEntry;

typedef struct {
  int32_t world_x;
  int32_t world_y;
  int8_t zoom;
} TileRequest;

extern TileCacheEntry *s_tiles;
extern AppTimer *s_visual_animation_timer;
extern int8_t s_viewport_zoom;
extern int s_tile_animation_mode;
extern bool s_touch_active;

void time_ms(time_t *seconds, uint16_t *milliseconds);
int active_tile_cache_size(void);
bool map_orientation_active(void);
int visible_tile_origins(TileRequest *origins, int max_count);
bool tile_origin_list_contains(const TileRequest *origins, int count,
                               int32_t world_x, int32_t world_y, int8_t zoom);
bool tile_is_visible(const TileCacheEntry *entry);
bool map_bearing_rendering_visible(void);
bool pan_inertia_animation_active(void);
bool zoom_fallback_active(void);
int normalize_tile_animation_mode(int mode);
void schedule_visual_animation_tick(void);
void release_visual_animation_tick_if_idle(void);

uint16_t tile_animation_duration_ms(uint8_t mode);
uint16_t tile_animation_elapsed_ms(const TileCacheEntry *entry);
uint16_t tile_animation_progress_q8(const TileCacheEntry *entry);
uint16_t tile_animation_eased_q8(uint16_t progress_q8);
void complete_tile_animation(TileCacheEntry *entry);
bool any_tile_animation_active(void);
void complete_tile_animations(void);
bool advance_tile_animations(void);
bool start_tile_animation(TileCacheEntry *entry, bool was_pending);

#endif
