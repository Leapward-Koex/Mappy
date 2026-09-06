#ifndef MAPPY_BEARING_SMOOTHING_H
#define MAPPY_BEARING_SMOOTHING_H

#include <stdbool.h>
#include <stdint.h>

// Millidegrees retain sub-pixel integration precision without floating point.
// Sample history changes only on observe(), never on a render tick.
typedef struct {
  int32_t display_milli_degrees;
  int32_t velocity_milli_per_second;
  int32_t target_milli_degrees;
  int32_t sensor_velocity_milli_per_second;
  uint32_t sampled_at_ms;
  uint32_t advanced_at_ms;
  uint16_t sample_period_ms;
  uint8_t rest_blend_ms;
  uint8_t directional_samples;
  int8_t direction;
  bool valid;
  bool has_sample;
  bool prediction_allowed;
  bool moving;
  bool acquiring;
} BearingTracker;

void bearing_tracker_reset(BearingTracker *state);
void bearing_tracker_snap(BearingTracker *state, int32_t heading_centi,
                          uint32_t now_ms);
// Advance the OLD private trajectory to the event time, then retarget without
// changing position or velocity at that instant. The caller publishes display
// only on its shared render clock. Repeated real readings are observations;
// camera synchronization must use set_target(), not observe().
void bearing_tracker_observe(BearingTracker *state, int32_t heading_centi,
                             uint32_t sampled_at_ms, bool allow_prediction);
void bearing_tracker_set_target(BearingTracker *state, int32_t heading_centi,
                                uint32_t now_ms);
void bearing_tracker_request_acquisition(BearingTracker *state, uint32_t now_ms);
int32_t bearing_tracker_advance(BearingTracker *state, uint32_t now_ms);
bool bearing_tracker_active(const BearingTracker *state, uint32_t now_ms);
int32_t bearing_tracker_display_centi_degrees(const BearingTracker *state);
int32_t bearing_tracker_velocity_centi_degrees_per_second(
    const BearingTracker *state);
int32_t bearing_tracker_prediction_centi_degrees(const BearingTracker *state,
                                                uint32_t now_ms);
int32_t bearing_smoothing_shortest_delta(int32_t from_centi, int32_t to_centi);

#endif
