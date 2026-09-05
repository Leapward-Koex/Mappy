#include "bearing_smoothing.h"

// Preserve sub-degree frames between compass events. A four-degree minimum
// snapped ordinary sensor updates in one tick, tying visible motion to the
// sensor cadence. Quarter-residual steps instead provide a cheap circular
// low-pass response; the small floor finishes the tail and lets rendering idle.
#define NORMAL_MIN_STEP_CENTI_DEGREES 25
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

int32_t bearing_smoothing_advance_ticks(int32_t current_centi,
                                        int32_t target_centi,
                                        bool fast_reacquire,
                                        uint8_t tick_count) {
  while (tick_count-- > 0 && bearing_smoothing_shortest_delta(
                                  current_centi, target_centi) != 0) {
    current_centi = bearing_smoothing_advance(current_centi, target_centi,
                                               fast_reacquire);
  }
  return current_centi;
}

// Inspired by Casiez et al.'s 1 Euro filter (https://gery.casiez.net/1euro/):
// reduce jitter at low speed, increase the cutoff during a deliberate turn.
// Only the derivative is filtered at sensor cadence. The heading is filtered
// once, by the render clock, avoiding a second sensor-filter/interpolation lag.
void bearing_smoothing_adaptive_reset(BearingSmoothingAdaptive *state) {
  *state = (BearingSmoothingAdaptive){0};
}

void bearing_smoothing_adaptive_observe(BearingSmoothingAdaptive *state,
                                         int32_t heading_centi,
                                         uint32_t sampled_at_ms) {
  if (heading_centi < 0) {
    bearing_smoothing_adaptive_reset(state);
    return;
  }
  heading_centi = normalize_centi_degrees(heading_centi);
  if (state->valid && heading_centi == state->heading_centi) {
    return;  // Reusing a held target is not a new sensor sample.
  }
  uint32_t elapsed = sampled_at_ms - state->sampled_at_ms;
  if (!state->valid || elapsed > 1000) {
    state->velocity_centi_per_second = 0;
  } else if (elapsed == 0) {
    // Keep the latest raw value, but do not invent a derivative interval.
    state->heading_centi = heading_centi;
    return;
  } else {
    int32_t velocity = bearing_smoothing_shortest_delta(
        state->heading_centi, heading_centi) * 1000 / (int32_t)elapsed;
    if (velocity > 72000) velocity = 72000;
    if (velocity < -72000) velocity = -72000;
    // Signed speed suppresses alternating compass jitter before abs() is
    // taken. Alpha = dt / (80ms + dt), using the actual sensor interval.
    state->velocity_centi_per_second +=
        (velocity - state->velocity_centi_per_second) * (int32_t)elapsed /
        (80 + (int32_t)elapsed);
  }
  state->heading_centi = heading_centi;
  state->sampled_at_ms = sampled_at_ms;
  state->valid = true;
}

int32_t bearing_smoothing_adaptive_advance_ticks(
    const BearingSmoothingAdaptive *state, int32_t current_centi,
    int32_t target_centi, bool fast_reacquire, uint8_t tick_count,
    uint32_t now_ms) {
  if (fast_reacquire) {
    return bearing_smoothing_advance_ticks(current_centi, target_centi, true,
                                            tick_count);
  }
  uint32_t sample_age_ms = now_ms - state->sampled_at_ms;
  int32_t speed = state->valid && sample_age_ms <= 500 ?
      state->velocity_centi_per_second : 0;
  if (speed < 0) speed = -speed;
  // Compass events stop when the angle is held. Age the effective speed rather
  // than feeding invented zero-speed samples into the sensor derivative.
  if (speed != 0) speed = speed * 100 / (100 + (int32_t)sample_age_ms);
  // 1Hz minimum + 0.15Hz per degree/second above an 8deg/s noise band.
  // tau = 1/(2*pi*cutoff); integer milliseconds avoid floating-point code.
  int32_t cutoff_millihz = 1000 + (speed > 800 ? (speed - 800) * 3 / 2 : 0);
  int32_t tau_ms = 159000 / cutoff_millihz;
  if (tau_ms < 10) tau_ms = 10;
  int32_t alpha_q8 = (256 * 30) / (tau_ms + 30);
  while (tick_count-- > 0) {
    int32_t delta = bearing_smoothing_shortest_delta(current_centi, target_centi);
    int32_t magnitude = delta < 0 ? -delta : delta;
    // A first heading or long sensor gap cannot provide a reliable velocity.
    // Large visible errors still catch up promptly; the six-degree threshold
    // leaves ordinary stationary noise on the low-cutoff response.
    int32_t error_alpha = magnitude > 600 ? 64 + (magnitude - 600) / 16 : 0;
    if (error_alpha > 192) error_alpha = 192;
    int32_t response = alpha_q8 > error_alpha ? alpha_q8 : error_alpha;
    int32_t step = clamp_step((magnitude * response + 128) / 256, 5,
                              NORMAL_MAX_STEP_CENTI_DEGREES);
    if (magnitude <= step) {
      return normalize_centi_degrees(target_centi);
    }
    current_centi = normalize_centi_degrees(
        current_centi + (delta > 0 ? step : -step));
  }
  return current_centi;
}
uint8_t bearing_smoothing_consume_elapsed_ticks(uint32_t *accumulated_ms,
                                                uint32_t elapsed_ms,
                                                uint16_t tick_ms,
                                                uint8_t max_ticks) {
  if (!accumulated_ms || tick_ms == 0 || max_ticks == 0) {
    return 0;
  }
  uint64_t total = (uint64_t)*accumulated_ms + elapsed_ms;
  *accumulated_ms = total > UINT32_MAX ? UINT32_MAX : (uint32_t)total;
  uint32_t ready = *accumulated_ms / tick_ms;
  uint8_t consumed = ready > max_ticks ? max_ticks : (uint8_t)ready;
  *accumulated_ms -= (uint32_t)consumed * tick_ms;
  return consumed;
}
