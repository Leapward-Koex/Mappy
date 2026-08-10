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

#endif
