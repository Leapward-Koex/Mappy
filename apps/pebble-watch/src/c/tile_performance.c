#include "mappy.h"

#if defined(MAPPY_WATCH_PHONE_MODE_FIXTURE) || defined(MAPPY_WATCH_HARDWARE_PERF)
// Local diagnostics only: no additional AppMessage traffic or production RAM.
// A frame means completion of a draw that submitted the visible tile. It is
// deliberately measured separately from the phone's transport acknowledgement.
typedef struct {
  TileCacheEntry *entry;
  TileRequest request;
  int32_t request_id;
  uint32_t accepted_ms;
} TileFrameMeasurement;

static TileFrameMeasurement s_pending_frames[2];
static uint32_t s_receive_started_ms;
static int32_t s_decode_ms;

static int32_t measured_elapsed_ms(uint32_t end, uint32_t start) {
  int32_t elapsed = (int32_t)(end - start);
  // The SDK exposes wall time; a clock correction must not appear as a huge
  // latency. A negative measurement is invalid and is logged as -1.
  return elapsed >= 0 ? elapsed : -1;
}

uint32_t tile_performance_clock(void) {
  time_t seconds;
  uint16_t millis;
  time_ms(&seconds, &millis);
  return (uint32_t)seconds * 1000u + millis;
}

void tile_performance_begin(void) {
  s_receive_started_ms = tile_performance_clock();
  s_decode_ms = 0;
}

void tile_performance_decode_end(uint32_t started_ms) {
  int32_t elapsed = measured_elapsed_ms(tile_performance_clock(), started_ms);
  s_decode_ms = s_decode_ms < 0 || elapsed < 0 ? -1 : s_decode_ms + elapsed;
}

void tile_performance_accepted(const TileFlight *flight, TileCacheEntry *entry,
                                int32_t format, int32_t bytes) {
  uint32_t now_ms = tile_performance_clock();
  int32_t request_ms = measured_elapsed_ms(now_ms,
      (uint32_t)flight->started_s * 1000u + flight->started_ms);
  APP_LOG(APP_LOG_LEVEL_INFO,
          "MAPPY_TILE id=%ld codec=%ld bytes=%ld decode=%ld receive=%ld request=%ld",
          (long)flight->request_id, (long)format, (long)bytes,
          (long)s_decode_ms,
          (long)measured_elapsed_ms(now_ms, s_receive_started_ms),
          (long)request_ms);
  if (!tile_is_visible(entry)) {
    return;
  }
  int slot = -1;
  for (int i = 0; i < 2; i++) {
    if (s_pending_frames[i].entry == entry) {
      slot = i;
      break;
    }
    if (!s_pending_frames[i].entry) {
      slot = i;
    }
  }
  if (slot < 0) {
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_TILE_FRAME dropped=1");
    return;
  }
  s_pending_frames[slot] = (TileFrameMeasurement){
    .entry = entry, .request = flight->request,
    .request_id = flight->request_id, .accepted_ms = now_ms,
  };
}

void tile_performance_rendered(TileCacheEntry **entries, int count) {
  for (int i = 0; i < 2; i++) {
    TileFrameMeasurement *pending = &s_pending_frames[i];
    TileCacheEntry *entry = pending->entry;
    if (!entry) {
      continue;
    }
    if (!entry->valid || entry->world_x != pending->request.world_x ||
        entry->world_y != pending->request.world_y ||
        entry->zoom != pending->request.zoom) {
      pending->entry = NULL;
      continue;
    }
    if (!tile_is_visible(entry) ||
        (entry->animation_active && tile_animation_progress_q8(entry) == 0)) {
      continue;
    }
    for (int j = 0; j < count; j++) {
      if (entries[j] == entry) {
        APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_TILE_FRAME id=%ld ms=%ld",
                (long)pending->request_id,
                (long)measured_elapsed_ms(tile_performance_clock(), pending->accepted_ms));
        pending->entry = NULL;
        break;
      }
    }
  }
}
#endif
