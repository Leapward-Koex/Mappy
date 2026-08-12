#ifndef MAPPY_BEARING_SMOOTHING_H
#define MAPPY_BEARING_SMOOTHING_H

#include <stdbool.h>
#include <stdint.h>

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
