#include "bearing_trace.h"

#ifdef MAPPY_BEARING_TRACE
#ifndef MAPPY_BEARING_TRACE_HOST_TEST
#include <pebble.h>
#endif
#include <stdlib.h>
#include <string.h>

bool visual_animations_active(void);

#define TRACE_CAPACITY 64
#define TRACE_CHUNK_RECORDS 4
#define TRACE_FLUSH_INTERVAL_MS 20

typedef struct {
  uint32_t at_ms;
  uint16_t raw_centi;
  uint16_t target_centi;
  uint16_t display_centi;
  int16_t velocity_deci_per_second;
  uint16_t sample_age_ms;
  uint8_t frame_interval_ms;
  uint8_t flags;
} BearingTraceRecord;
typedef char BearingTraceRecordMustBe16Bytes[
    sizeof(BearingTraceRecord) == 16 ? 1 : -1];

static struct {
  BearingTraceRecord *records;
  uint32_t sampled_at_ms;
  uint32_t previous_frame_ms;
  uint32_t dropped;
  AppTimer *timer;
  uint16_t raw_centi;
  uint8_t head;
  uint8_t count;
  uint8_t quality;
  bool initialized;
  bool active;
  bool dumping;
  bool frame_seen;
} s_trace;

static void trace_flush_callback(void *context);

static void trace_schedule_flush(void) {
  if (!s_trace.active && s_trace.count && !s_trace.timer) {
    // Allocation failure retains the buffer; the next idle notification can
    // retry. Never fall back to logging synchronously in a rendering callback.
    s_trace.timer = app_timer_register(TRACE_FLUSH_INTERVAL_MS,
                                      trace_flush_callback, NULL);
  }
}

static void trace_flush_callback(void *context) {
  (void)context;
  s_trace.timer = NULL;
  if (s_trace.active || !s_trace.count) {
    return;
  }
  // Bearing can idle while a pan, tile reveal or menu still needs frames.
  // Defer all log output until the shared visual scheduler is idle too.
  if (visual_animations_active()) {
    trace_schedule_flush();
    return;
  }
  if (!s_trace.dumping) {
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_BTRACE begin n=%u drop=%lu",
            (unsigned)s_trace.count, (unsigned long)s_trace.dropped);
    s_trace.dumping = true;
  }
  for (unsigned i = 0; i < TRACE_CHUNK_RECORDS && s_trace.count; i++) {
    const BearingTraceRecord *record = &s_trace.records[s_trace.head];
    APP_LOG(APP_LOG_LEVEL_INFO,
            "MAPPY_BTRACE t=%lu r=%u g=%u p=%u v=%d a=%u dt=%u f=%u",
            (unsigned long)record->at_ms, (unsigned)record->raw_centi,
            (unsigned)record->target_centi, (unsigned)record->display_centi,
            (int)record->velocity_deci_per_second,
            (unsigned)record->sample_age_ms,
            (unsigned)record->frame_interval_ms, (unsigned)record->flags);
    s_trace.head = (s_trace.head + 1) & (TRACE_CAPACITY - 1);
    s_trace.count--;
  }
  if (s_trace.count) {
    trace_schedule_flush();
  } else {
    s_trace.dropped = 0;
    s_trace.dumping = false;
  }
}

void bearing_trace_init(void) {
  if (s_trace.initialized) return;
  s_trace.initialized = true;
  s_trace.records = malloc(TRACE_CAPACITY * sizeof(*s_trace.records));
  if (!s_trace.records) {
    APP_LOG(APP_LOG_LEVEL_INFO, "MAPPY_BTRACE allocation failed");
  }
}

void bearing_trace_sample(uint32_t at_ms, int32_t raw_centi,
                            uint8_t quality_flags) {
  s_trace.sampled_at_ms = at_ms;
  s_trace.raw_centi = (uint16_t)raw_centi;
  s_trace.quality = raw_centi >= 0 ?
      quality_flags & (BearingTraceRawValid | BearingTraceCalibrated) : 0;
}

void bearing_trace_frame(uint32_t at_ms, int32_t target_centi,
                           int32_t display_centi,
                           int32_t display_velocity_centi_per_second,
                           uint8_t state_flags) {
  if (!s_trace.records) return;
  uint32_t age = s_trace.quality & BearingTraceRawValid ?
      at_ms - s_trace.sampled_at_ms : UINT32_MAX;
  uint32_t interval = s_trace.frame_seen ? at_ms - s_trace.previous_frame_ms : 0;
  uint8_t flags = s_trace.quality | (state_flags & 0x3c);
  if (age >= UINT16_MAX) flags |= BearingTraceAgeClamped;
  if (interval > UINT8_MAX) flags |= BearingTraceIntervalClamped;
  if (s_trace.count == TRACE_CAPACITY) {
    s_trace.head = (s_trace.head + 1) & (TRACE_CAPACITY - 1);
    s_trace.count--;
    if (s_trace.dropped < UINT32_MAX) s_trace.dropped++;
  }
  BearingTraceRecord *record = &s_trace.records[
      (s_trace.head + s_trace.count++) & (TRACE_CAPACITY - 1)];
  *record = (BearingTraceRecord){
    .at_ms = at_ms,
    .raw_centi = s_trace.quality & BearingTraceRawValid ?
        s_trace.raw_centi : UINT16_MAX,
    .target_centi = (uint16_t)target_centi,
    .display_centi = (uint16_t)display_centi,
    .velocity_deci_per_second = (int16_t)(display_velocity_centi_per_second / 10),
    .sample_age_ms = age >= UINT16_MAX ? UINT16_MAX : (uint16_t)age,
    .frame_interval_ms = interval > UINT8_MAX ? UINT8_MAX : (uint8_t)interval,
    .flags = flags,
  };
  s_trace.previous_frame_ms = at_ms;
  s_trace.frame_seen = true;
}

void bearing_trace_set_active(bool active) {
  s_trace.active = active;
  if (active) {
    if (s_trace.timer) {
      app_timer_cancel(s_trace.timer);
      s_trace.timer = NULL;
    }
    // A resumed gesture may extend/overwrite a partly dumped buffer. The next
    // idle chunk starts with fresh count/drop metadata for what remains.
    s_trace.dumping = false;
  } else {
    trace_schedule_flush();
  }
}

void bearing_trace_shutdown(void) {
  if (s_trace.timer) {
    app_timer_cancel(s_trace.timer);
  }
  free(s_trace.records);
  memset(&s_trace, 0, sizeof(s_trace));
}
#endif
