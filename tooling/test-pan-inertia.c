#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "../apps/pebble-watch/src/c/pan_inertia.h"

static int s_failures;

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: %s\n", message); \
    s_failures++; \
  } \
} while (0)

static bool start_horizontal(PanInertiaState *state, int32_t displacement,
                             uint32_t elapsed_ms) {
  pan_inertia_reset(state, 0, 0);
  pan_inertia_observe(state, displacement, 0, elapsed_ms);
  return pan_inertia_start(state);
}

static void test_state_size_and_sample_timing(void) {
  PanInertiaState state;
  CHECK(sizeof(state) <= 40, "production inertia state must not exceed 40 bytes");

  pan_inertia_reset(&state, 40, -20);
  CHECK(!pan_inertia_is_active(&state), "reset state must be inactive");
  pan_inertia_observe(&state, 41, -20, 3);
  CHECK(!pan_inertia_start(&state),
        "a lone sub-8ms sample must not produce a release velocity");

  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 1, 0, 3);
  pan_inertia_observe(&state, 2, 0, 3);
  pan_inertia_observe(&state, 4, 0, 3);
  CHECK(pan_inertia_start(&state),
        "sub-8ms observations must combine into a stable sample");
  int32_t x = 4;
  int32_t y = 0;
  CHECK(pan_inertia_advance(&state, 30, &x, &y) && x == 17,
        "combined observations must retain their total displacement and time");

  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 10, 0, 30);
  pan_inertia_observe(&state, 100, 0, 121);
  CHECK(!pan_inertia_start(&state),
        "a gap over 120ms must discard prior velocity history");
}

static void test_release_idle_and_start_threshold(void) {
  PanInertiaState state;
  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 10, 0, 30);
  pan_inertia_observe(&state, 10, 0, 80);
  CHECK(pan_inertia_start(&state),
        "a release exactly 80ms after movement may still coast");

  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 10, 0, 30);
  pan_inertia_observe(&state, 10, 0, 81);
  CHECK(!pan_inertia_start(&state),
        "a release more than 80ms after movement must not coast");

  CHECK(!start_horizontal(&state, 1, 30),
        "a one-pixel-per-tick drag must remain below the start threshold");
  CHECK(start_horizontal(&state, 2, 30),
        "a two-pixel-per-tick drag must meet the start threshold");
  CHECK(!start_horizontal(&state, -1, 30),
        "the start threshold must be symmetric for negative motion");
  CHECK(start_horizontal(&state, -2, 30),
        "the negative start threshold must match the positive threshold");
}

static void test_ema_and_reversal(void) {
  PanInertiaState state;
  int32_t x;
  int32_t y = 0;

  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 8, 0, 30);
  pan_inertia_observe(&state, 20, 0, 30);
  CHECK(pan_inertia_start(&state), "EMA profile must start for a fast drag");
  x = 20;
  pan_inertia_advance(&state, 30, &x, &y);
  CHECK(x == 31,
        "velocity EMA must weight the newest sample 75 percent");

  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 12, 0, 30);
  pan_inertia_observe(&state, 0, 0, 30);
  CHECK(pan_inertia_start(&state),
        "a strong reversal must replace the prior release direction");
  x = 0;
  y = 0;
  pan_inertia_advance(&state, 30, &x, &y);
  CHECK(x == -6, "EMA reversal must coast in the newest direction");
}

static void test_direction_preserving_cap(void) {
  PanInertiaState state;
  int32_t x = 100;
  int32_t y = 0;
  CHECK(start_horizontal(&state, 100, 30), "fast positive drag must start");
  pan_inertia_advance(&state, 30, &x, &y);
  CHECK(x == 114 && y == 0, "positive velocity must cap at 14px per tick");

  x = -100;
  y = 0;
  CHECK(start_horizontal(&state, -100, 30), "fast negative drag must start");
  pan_inertia_advance(&state, 30, &x, &y);
  CHECK(x == -114 && y == 0,
        "negative velocity must use the same 14px cap");

  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 100, 50, 30);
  CHECK(pan_inertia_start(&state), "fast diagonal drag must start");
  x = 100;
  y = 50;
  pan_inertia_advance(&state, 30, &x, &y);
  CHECK(x == 111 && y == 55,
        "vector capping must preserve diagonal direction approximately");

  PanInertiaState positive;
  PanInertiaState negative;
  CHECK(start_horizontal(&positive, 100, 30),
        "positive symmetry profile must start");
  CHECK(start_horizontal(&negative, -100, 30),
        "negative symmetry profile must start");
  int32_t positive_x = 100;
  int32_t negative_x = -100;
  int32_t positive_y = 0;
  int32_t negative_y = 0;
  pan_inertia_advance(&positive, 360, &positive_x, &positive_y);
  pan_inertia_advance(&negative, 360, &negative_x, &negative_y);
  CHECK(positive_x - 100 == -(negative_x + 100),
        "full-coast displacement must remain sign symmetric");
}

static void test_fractional_time_and_catchup(void) {
  PanInertiaState fractional;
  pan_inertia_reset(&fractional, 0, 0);
  pan_inertia_observe(&fractional, 1, 0, 12);
  CHECK(pan_inertia_start(&fractional),
        "a 2.5px-per-tick fractional velocity must start");
  int32_t x = 1;
  int32_t y = 0;
  CHECK(!pan_inertia_advance(&fractional, 29, &x, &y) && x == 1,
        "sub-tick elapsed time must not move the viewport");
  CHECK(pan_inertia_advance(&fractional, 1, &x, &y) && x == 3,
        "retained elapsed time must release one logical tick");
  pan_inertia_advance(&fractional, 30, &x, &y);
  CHECK(x == 5, "Q8 displacement remainder must carry across ticks");

  PanInertiaState stepped;
  PanInertiaState delayed;
  CHECK(start_horizontal(&stepped, 10, 30), "stepped profile must start");
  CHECK(start_horizontal(&delayed, 10, 30), "delayed profile must start");
  int32_t stepped_x = 10;
  int32_t delayed_x = 10;
  int32_t stepped_y = 0;
  int32_t delayed_y = 0;
  for (int i = 0; i < 4; i++) {
    pan_inertia_advance(&stepped, 30, &stepped_x, &stepped_y);
  }
  CHECK(pan_inertia_advance(&delayed, 120, &delayed_x, &delayed_y),
        "a delayed callback must consume every ready logical tick");
  CHECK(delayed_x == stepped_x && delayed_y == stepped_y &&
            delayed.tick_count == stepped.tick_count,
        "delayed and on-time advancement must end at the same viewport");
}

static void test_bounded_lifetime_and_cancel(void) {
  PanInertiaState state;
  CHECK(start_horizontal(&state, 100, 30), "capped lifetime profile must start");
  int32_t x = 100;
  int32_t y = 0;
  int calls = 0;
  while (pan_inertia_is_active(&state) && calls < 20) {
    pan_inertia_advance(&state, 30, &x, &y);
    calls++;
  }
  CHECK(calls == 12 && state.tick_count == 12,
        "maximum-speed inertia must stop after 12 logical ticks");
  CHECK(x - 100 > 0 && x - 100 <= 70,
        "maximum-speed coast must remain within roughly 70 pixels");

  CHECK(start_horizontal(&state, 100, 30),
        "maximum elapsed-time profile must start");
  x = 100;
  y = 0;
  CHECK(pan_inertia_advance(&state, UINT32_MAX, &x, &y) &&
            !pan_inertia_is_active(&state) && state.tick_count == 12 &&
            x - 100 <= 70,
        "UINT32_MAX elapsed time must safely consume only the bounded coast");

  CHECK(start_horizontal(&state, 10, 30), "cancel profile must start");
  pan_inertia_cancel(&state);
  x = 10;
  y = 0;
  CHECK(!pan_inertia_is_active(&state) &&
            !pan_inertia_advance(&state, 300, &x, &y) && x == 10,
        "cancellation must stop all pending movement immediately");
}

static void test_signed_saturation(void) {
  PanInertiaState state;
  CHECK(start_horizontal(&state, 100, 30), "positive saturation profile must start");
  int32_t x = INT32_MAX - 3;
  int32_t y = 0;
  CHECK(pan_inertia_advance(&state, 30, &x, &y) && x == INT32_MAX,
        "positive coast must saturate at INT32_MAX");
  CHECK(!pan_inertia_advance(&state, 30, &x, &y) && x == INT32_MAX,
        "outward motion at INT32_MAX must remain saturated");

  CHECK(start_horizontal(&state, -100, 30), "negative saturation profile must start");
  x = INT32_MIN + 3;
  y = 0;
  CHECK(pan_inertia_advance(&state, 30, &x, &y) && x == INT32_MIN,
        "negative coast must saturate at INT32_MIN");
  CHECK(!pan_inertia_advance(&state, 30, &x, &y) && x == INT32_MIN,
        "outward motion at INT32_MIN must remain saturated");

  pan_inertia_reset(&state, 0, 0);
  pan_inertia_observe(&state, 100, 50, 30);
  CHECK(pan_inertia_start(&state),
        "mixed-axis saturation profile must start");
  x = INT32_MAX - 3;
  y = 0;
  CHECK(pan_inertia_advance(&state, 30, &x, &y) &&
            x == INT32_MAX && y == 5,
        "one saturated axis must not suppress movement on the other axis");
  CHECK(pan_inertia_advance(&state, 30, &x, &y) &&
            x == INT32_MAX && y > 5,
        "the unsaturated axis must keep moving after its peer reaches a bound");

  CHECK(start_horizontal(&state, -100, 30),
        "inward boundary profile must start");
  x = INT32_MAX;
  y = 0;
  CHECK(pan_inertia_advance(&state, 30, &x, &y) && x == INT32_MAX - 14,
        "motion away from INT32_MAX must not be clamped");

  pan_inertia_reset(&state, INT32_MIN, 0);
  pan_inertia_observe(&state, INT32_MAX, 0, 30);
  CHECK(pan_inertia_start(&state),
        "extreme observed coordinates must not overflow velocity sampling");

  pan_inertia_reset(&state, INT32_MIN, INT32_MAX);
  pan_inertia_observe(&state, INT32_MIN + 1, INT32_MAX - 1, 3);
  pan_inertia_observe(&state, INT32_MAX, INT32_MIN, 5);
  CHECK(pan_inertia_start(&state),
        "combined extreme coordinates must preserve an overflow-safe sample");
  x = 0;
  y = 0;
  pan_inertia_advance(&state, 30, &x, &y);
  CHECK(x > 0 && y < 0,
        "extreme combined samples must retain both motion signs");
}

int main(void) {
  test_state_size_and_sample_timing();
  test_release_idle_and_start_threshold();
  test_ema_and_reversal();
  test_direction_preserving_cap();
  test_fractional_time_and_catchup();
  test_bounded_lifetime_and_cancel();
  test_signed_saturation();
  if (s_failures != 0) {
    fprintf(stderr, "pan inertia tests: %d failure(s)\n", s_failures);
    return 1;
  }
  printf("pan inertia tests: all checks passed (state=%u bytes)\n",
         (unsigned)sizeof(PanInertiaState));
  return 0;
}
