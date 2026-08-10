#include "bearing_smoothing.h"

#define NORMAL_MIN_STEP_CENTI_DEGREES 400
#define NORMAL_MAX_STEP_CENTI_DEGREES 1200
#define NORMAL_STEP_DIVISOR 4
#define FAST_MIN_STEP_CENTI_DEGREES 800
#define FAST_MAX_STEP_CENTI_DEGREES 2400
#define FAST_STEP_DIVISOR 3

static int32_t clamp_step(int32_t step, int32_t minimum, int32_t maximum) {
  if (step < minimum) {
    return minimum;
  }
  if (step > maximum) {
    return maximum;
  }
  return step;
}

static int32_t normalize_centi_degrees(int32_t centi_degrees) {
  int32_t normalized = centi_degrees % 36000;
  return normalized < 0 ? normalized + 36000 : normalized;
}

int32_t bearing_smoothing_step_centi_degrees(int32_t abs_delta,
                                             bool fast_reacquire) {
  if (fast_reacquire) {
    return clamp_step(abs_delta / FAST_STEP_DIVISOR,
                      FAST_MIN_STEP_CENTI_DEGREES,
                      FAST_MAX_STEP_CENTI_DEGREES);
  }
  return clamp_step(abs_delta / NORMAL_STEP_DIVISOR,
                    NORMAL_MIN_STEP_CENTI_DEGREES,
                    NORMAL_MAX_STEP_CENTI_DEGREES);
}

int32_t bearing_smoothing_shortest_delta(int32_t from_centi,
                                         int32_t to_centi) {
  int32_t delta = normalize_centi_degrees(to_centi - from_centi);
  return delta > 18000 ? delta - 36000 : delta;
}

int32_t bearing_smoothing_advance(int32_t current_centi,
                                  int32_t target_centi,
                                  bool fast_reacquire) {
  int32_t delta = bearing_smoothing_shortest_delta(current_centi,
                                                   target_centi);
  if (delta == 0) {
    return normalize_centi_degrees(target_centi);
  }
  int32_t abs_delta = delta < 0 ? -delta : delta;
  int32_t step = bearing_smoothing_step_centi_degrees(abs_delta,
                                                      fast_reacquire);
  // Split the last 24..48 degrees evenly, then coalesce the final <=24-degree
  // tail. Every frame remains within the cap and a 180-degree reacquisition
  // completes in at most eight 30ms ticks.
  if (fast_reacquire && abs_delta > 2400 && abs_delta <= 4800) {
    step = (abs_delta + 1) / 2;
  }
  if (abs_delta <= step || (fast_reacquire && abs_delta <= 2400)) {
    return normalize_centi_degrees(target_centi);
  }
  return normalize_centi_degrees(current_centi + (delta > 0 ? step : -step));
}
