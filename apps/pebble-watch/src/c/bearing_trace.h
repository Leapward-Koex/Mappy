#ifndef MAPPY_BEARING_TRACE_H
#define MAPPY_BEARING_TRACE_H

#include <stdbool.h>
#include <stdint.h>

// Quality comes from fresh sensor callbacks; state comes from the render tick.
enum {
  BearingTraceRawValid = 1 << 0,
  BearingTraceCalibrated = 1 << 1,
  BearingTraceReacquiring = 1 << 2,
  BearingTracePredicting = 1 << 3,
  BearingTraceMoving = 1 << 4,
  BearingTraceFaceForward = 1 << 5,
  BearingTraceAgeClamped = 1 << 6,
  BearingTraceIntervalClamped = 1 << 7,
};

#ifdef MAPPY_BEARING_TRACE
// Init allocates a 64-record (1024-byte) ring once, before compass delivery.
// Sample/frame hooks never allocate or log: sample caches the raw observation;
// frame snapshots raw/target/display. Shutdown frees the ring and is idempotent.
// Angles are normalized centidegrees (0..35999), or -1 for invalid; velocity
// comes from the controller's +/-72000 centidegrees/second bound. Logs store
// velocity in 0.1 degree/second units. Timestamp/flags retain rate/mode offline.
void bearing_trace_init(void);
void bearing_trace_sample(uint32_t at_ms, int32_t raw_centi,
                            uint8_t quality_flags);
void bearing_trace_frame(uint32_t at_ms, int32_t target_centi,
                           int32_t display_centi,
                           int32_t display_velocity_centi_per_second,
                           uint8_t state_flags);
// Call after recording the final frame. Active cancels a pending flush; idle
// drains at most four records per 20ms callback. Shutdown discards pending data.
void bearing_trace_set_active(bool active);
void bearing_trace_shutdown(void);
#else
// Arguments are not evaluated: production builds have no trace work or state.
#define bearing_trace_init() ((void)0)
#define bearing_trace_sample(...) ((void)0)
#define bearing_trace_frame(...) ((void)0)
#define bearing_trace_set_active(...) ((void)0)
#define bearing_trace_shutdown() ((void)0)
#endif

#endif
