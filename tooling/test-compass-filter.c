#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "../apps/pebble-watch/src/c/compass_filter.h"

static int s_failures;

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: %s\n", message); \
    s_failures++; \
  } \
} while (0)

static CompassFilterResult sample(CompassFilter *filter,
                                  CompassFilterStatus status,
                                  int heading, uint32_t now_ms) {
  return compass_filter_process(filter, status, (int16_t)heading, now_ms);
}

static void test_status_policy(void) {
  CompassFilter filter;
  compass_filter_reset(&filter, 0);
  CompassFilterResult result = sample(
      &filter, CompassFilterStatusUnavailable, 0, 1);
  CHECK(!filter.heading_usable,
        "unavailable compass must never produce a usable heading");
  CHECK(result & CompassFilterResultServiceUnavailable,
        "unavailable transition must be reported");

  result = sample(&filter, CompassFilterStatusDataInvalid, 180, 2);
  CHECK(!filter.heading_usable,
        "data-invalid compass must never produce a usable heading");
  CHECK(result & CompassFilterResultStatusChanged,
        "data-invalid transition must be reported");

  result = sample(&filter, CompassFilterStatusCalibrated, 42, 3);
  CHECK(filter.heading_usable && filter.accepted_heading == 42,
        "first calibrated sample must be accepted immediately");
  CHECK(result & CompassFilterResultHeadingAcquired,
        "first calibrated sample must report acquisition");

  result = sample(&filter, CompassFilterStatusCalibrating, 43, 4);
  CHECK(!filter.heading_usable,
        "entering calibration must invalidate a prior heading");
  CHECK((result & CompassFilterResultCalibrationStarted) &&
        (result & CompassFilterResultHeadingLost),
        "entering calibration must report calibration and heading loss");

  result = sample(&filter, CompassFilterStatusCalibrated, -1, 5);
  CHECK(filter.status == CompassFilterStatusDataInvalid &&
        !filter.heading_usable,
        "invalid heading payload must be represented as data-invalid");
  CHECK(result & CompassFilterResultStatusChanged,
        "invalid calibrated payload must report its effective status change");
}

static void test_calibration_gate(void) {
  CompassFilter filter;
  compass_filter_reset(&filter, 0);
  sample(&filter, CompassFilterStatusCalibrating, 10, 0);
  sample(&filter, CompassFilterStatusCalibrating, 12, 100);
  CompassFilterResult result = sample(
      &filter, CompassFilterStatusCalibrating, 11, 200);
  CHECK(!filter.heading_usable,
        "three samples in less than 250ms must remain gated");
  CHECK(!(result & CompassFilterResultHeadingAcquired),
        "short calibration streak must not report acquisition");
  result = sample(&filter, CompassFilterStatusCalibrating, 9, 300);
  CHECK(filter.heading_usable && filter.accepted_heading == 9,
        "stable calibration streak spanning 250ms must acquire");
  CHECK(result & CompassFilterResultHeadingAcquired,
        "stable calibration streak must report acquisition");

  compass_filter_reset(&filter, 0);
  sample(&filter, CompassFilterStatusCalibrating, 359, 0);
  sample(&filter, CompassFilterStatusCalibrating, 1, 100);
  sample(&filter, CompassFilterStatusCalibrating, 0, 260);
  CHECK(filter.heading_usable && filter.accepted_heading == 0,
        "calibration spread must be circular across north");

  compass_filter_reset(&filter, 0);
  sample(&filter, CompassFilterStatusCalibrating, 0, 0);
  sample(&filter, CompassFilterStatusCalibrating, 30, 150);
  sample(&filter, CompassFilterStatusCalibrating, 1, 300);
  sample(&filter, CompassFilterStatusCalibrating, 31, 600);
  CHECK(!filter.heading_usable,
        "unstable calibrating samples must continually reset the streak");
}

static void test_deadband_and_normal_turns(void) {
  CompassFilter filter;
  compass_filter_reset(&filter, 0);
  sample(&filter, CompassFilterStatusCalibrated, 359, 0);
  sample(&filter, CompassFilterStatusCalibrated, 1, 20);
  CHECK(filter.accepted_heading == 359,
        "two-degree wraparound jitter must stay inside the deadband");
  sample(&filter, CompassFilterStatusCalibrated, 4, 40);
  CHECK(filter.accepted_heading == 4,
        "heading outside the deadband must be accepted");

  for (int heading = 14; heading <= 94; heading += 10) {
    sample(&filter, CompassFilterStatusCalibrated, heading,
           (uint32_t)(100 + heading));
  }
  CHECK(filter.accepted_heading == 94,
        "a gradual deliberate 90-degree turn must track normally");
}

static void test_outlier_confirmation(void) {
  CompassFilter filter;
  compass_filter_reset(&filter, 0);
  sample(&filter, CompassFilterStatusCalibrated, 0, 0);
  CompassFilterResult result = sample(
      &filter, CompassFilterStatusCalibrated, 180, 20);
  CHECK(filter.outlier_pending && filter.accepted_heading == 0,
        "a large jump must remain provisional");
  CHECK(result & CompassFilterResultOutlierPending,
        "a large jump must request confirmation");
  result = sample(&filter, CompassFilterStatusCalibrated, 178, 219);
  CHECK(filter.accepted_heading == 0,
        "a matching sample before 200ms must not confirm early");
  result = sample(&filter, CompassFilterStatusCalibrated, 181, 220);
  CHECK(filter.accepted_heading == 181 && !filter.outlier_pending,
        "a persistent large turn must confirm after 200ms");
  CHECK(result & CompassFilterResultHeadingAccepted,
        "confirmed turn must produce an accepted target");

  compass_filter_reset(&filter, 0);
  sample(&filter, CompassFilterStatusCalibrated, 0, 0);
  sample(&filter, CompassFilterStatusCalibrated, 180, 20);
  result = compass_filter_tick(&filter, 771);
  CHECK(filter.accepted_heading == 0 && !filter.outlier_pending,
        "an isolated 180-degree sample must expire without rotation");
  CHECK(result & CompassFilterResultOutlierRejected,
        "expired outlier must be reported");

  sample(&filter, CompassFilterStatusCalibrated, 100, 800);
  result = sample(&filter, CompassFilterStatusCalibrated, 2, 900);
  CHECK(filter.accepted_heading == 0 && !filter.outlier_pending,
        "returning to the current heading must cancel an outlier");
  CHECK(result & CompassFilterResultOutlierRejected,
        "return-to-current must report rejection");

  compass_filter_reset(&filter, 0);
  sample(&filter, CompassFilterStatusCalibrated, 0, 0);
  sample(&filter, CompassFilterStatusCalibrated, 90, 10);
  result = compass_filter_tick(&filter, 760);
  CHECK(filter.accepted_heading == 0 &&
        (result & CompassFilterResultOutlierRejected),
        "an isolated 90-degree sample must also be rejected");
  sample(&filter, CompassFilterStatusCalibrated, 90, 800);
  result = sample(&filter, CompassFilterStatusCalibrated, 92, 1000);
  CHECK(filter.accepted_heading == 92 &&
        (result & CompassFilterResultHeadingAccepted),
        "a sustained abrupt 90-degree turn must confirm after 200ms");
}

static void test_health_and_reacquisition(void) {
  CompassFilter filter;
  compass_filter_reset(&filter, 100);
  sample(&filter, CompassFilterStatusCalibrated, 270, 200);
  CompassFilterResult result = compass_filter_tick(
      &filter, 200 + COMPASS_FILTER_STALE_MS + 1);
  CHECK(filter.stale && !filter.heading_usable,
        "service silence beyond the deadline must invalidate heading");
  CHECK((result & CompassFilterResultStale) &&
        (result & CompassFilterResultHeadingLost),
        "health timeout must report stale heading loss");

  result = sample(&filter, CompassFilterStatusCalibrated, 275, 5300);
  CHECK(!filter.stale && filter.heading_usable &&
        filter.accepted_heading == 275,
        "a fresh calibrated sample must reacquire cleanly after timeout");
  CHECK(result & CompassFilterResultHeadingAcquired,
        "post-timeout reacquisition must be reported");
}

static void test_angle_math(void) {
  CHECK(compass_filter_shortest_delta(359, 1) == 2,
        "shortest delta must cross north clockwise");
  CHECK(compass_filter_shortest_delta(1, 359) == -2,
        "shortest delta must cross north counter-clockwise");
  CHECK(compass_filter_angular_distance(0, 180) == 180,
        "exact opposite headings must be 180 degrees apart");
}

int main(void) {
  test_status_policy();
  test_calibration_gate();
  test_deadband_and_normal_turns();
  test_outlier_confirmation();
  test_health_and_reacquisition();
  test_angle_math();
  if (s_failures != 0) {
    fprintf(stderr, "compass filter tests: %d failure(s)\n", s_failures);
    return 1;
  }
  printf("compass filter tests: all checks passed\n");
  return 0;
}
