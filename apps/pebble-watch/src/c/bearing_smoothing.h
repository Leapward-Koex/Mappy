#ifndef MAPPY_BEARING_SMOOTHING_H
#define MAPPY_BEARING_SMOOTHING_H

#include <stdbool.h>
#include <stdint.h>

// Sensor history only: the displayed angle remains the single filtered value.
typedef struct {
  uint32_t sampled_at_ms;
  int32_t heading_centi;
  int32_t velocity_centi_per_second;
  bool valid;
} BearingSmoothingAdaptive;

void bearing_smoothing_adaptive_reset(BearingSmoothingAdaptive *state);
void bearing_smoothing_adaptive_observe(BearingSmoothingAdaptive *state,
                                         int32_t heading_centi,
                                         uint32_t sampled_at_ms);
int32_t bearing_smoothing_adaptive_advance_ticks(
    const BearingSmoothingAdaptive *state, int32_t current_centi,
    int32_t target_centi, bool fast_reacquire, uint8_t tick_count,
    uint32_t now_ms);
int32_t bearing_smoothing_step_centi_degrees(int32_t abs_delta,
                                             bool fast_reacquire);
int32_t bearing_smoothing_shortest_delta(int32_t from_centi,
                                         int32_t to_centi);
int32_t bearing_smoothing_advance(int32_t current_centi,
                                  int32_t target_centi,
                                  bool fast_reacquire);
int32_t bearing_smoothing_advance_ticks(int32_t current_centi,
                                        int32_t target_centi,
                                        bool fast_reacquire,
                                        uint8_t tick_count);
uint8_t bearing_smoothing_consume_elapsed_ticks(uint32_t *accumulated_ms,
                                                uint32_t elapsed_ms,
                                                uint16_t tick_ms,
                                                uint8_t max_ticks);

#endif
