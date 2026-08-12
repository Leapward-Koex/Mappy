#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "../apps/pebble-watch/src/c/bearing_smoothing.h"
#include "../apps/pebble-watch/src/c/motion_detector.h"

#define SAMPLE_INTERVAL_MS 40

static int s_failures;

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: %s\n", message); \
    s_failures++; \
  } \
} while (0)

static MotionDetectorEvent feed(MotionDetector *detector, uint32_t *time_ms,
                                int16_t x, int16_t y, int16_t z,
                                bool did_vibrate) {
  MotionSample sample = {
    .x = x,
    .y = y,
    .z = z,
    .timestamp_ms = *time_ms,
    .did_vibrate = did_vibrate,
  };
  MotionDetectorEvent event = motion_detector_process(detector, &sample);
  *time_ms += SAMPLE_INTERVAL_MS;
  return event;
}

static int feed_pose(MotionDetector *detector, uint32_t *time_ms,
                     int16_t x, int16_t y, int16_t z, int samples,
                     MotionDetectorEvent wanted, uint32_t *event_time) {
  int count = 0;
  for (int i = 0; i < samples; i++) {
    uint32_t sample_time = *time_ms;
    MotionDetectorEvent event = feed(detector, time_ms, x, y, z, false);
    if (event & wanted) {
      count++;
      if (event_time) {
        *event_time = sample_time;
      }
    }
  }
  return count;
}

static int feed_walking_y(MotionDetector *detector, uint32_t *time_ms,
                          int samples, bool vibrate_peaks) {
  int walking_events = 0;
  for (int i = 0; i < samples; i++) {
    bool peak = i % 10 == 0;
    MotionDetectorEvent event = feed(detector, time_ms, 0,
        peak ? 1350 : 1000, 0, peak && vibrate_peaks);
    if (event & MotionDetectorEventWalking) {
      walking_events++;
    }
  }
  return walking_events;
}

static int feed_walking_z(MotionDetector *detector, uint32_t *time_ms,
                          int samples) {
  int walking_events = 0;
  for (int i = 0; i < samples; i++) {
    bool peak = i % 10 == 0;
    MotionDetectorEvent event = feed(detector, time_ms, 0, 0,
        peak ? 1350 : 1000, false);
    if (event & MotionDetectorEventWalking) {
      walking_events++;
    }
  }
  return walking_events;
}

static void replay_fixture(const char *path, int *walking_out,
                           int *looks_out, uint32_t *look_time_out) {
  FILE *fixture = fopen(path, "r");
  CHECK(fixture != NULL, "motion CSV fixture must be readable");
  if (!fixture) {
    return;
  }

  MotionDetector detector;
  motion_detector_reset(&detector);
  uint32_t now = 0;
  int walking = 0;
  int looks = 0;
  int x;
  int y;
  int z;
  while (fscanf(fixture, "%d,%d,%d", &x, &y, &z) == 3) {
    uint32_t sample_time = now;
    MotionDetectorEvent event = feed(&detector, &now, (int16_t)x,
                                     (int16_t)y, (int16_t)z, false);
    if (event & MotionDetectorEventWalking) {
      walking++;
    }
    if (event & MotionDetectorEventWatchLook) {
      looks++;
      if (look_time_out) {
        *look_time_out = sample_time;
      }
    }
  }
  fclose(fixture);
  if (walking_out) {
    *walking_out = walking;
  }
  if (looks_out) {
    *looks_out = looks;
  }
}

static void test_csv_fixtures(void) {
  int walking = 0;
  int looks = 0;
  uint32_t look_time = 0;
  replay_fixture("tooling/motion-fixtures/stationary-raise.csv",
                 &walking, &looks, NULL);
  CHECK(walking == 0 && looks == 0,
        "stationary raise CSV must not confirm walking or looking");

  walking = 0;
  looks = 0;
  replay_fixture("tooling/motion-fixtures/walking-to-look.csv",
                 &walking, &looks, &look_time);
  CHECK(walking == 1 && looks == 1,
        "walking-to-look CSV must emit one walking and one look event");
  CHECK(look_time >= 1800 && look_time - 1800 <= 600,
        "walking-to-look CSV must confirm within 600ms of the raised pose");
}

static void test_idle_and_false_raises(void) {
  MotionDetector detector;
  uint32_t now = 0;
  motion_detector_reset(&detector);
  int looks = feed_pose(&detector, &now, 0, 1000, 0, 50,
                        MotionDetectorEventWatchLook, NULL);
  looks += feed_pose(&detector, &now, 0, 0, 1000, 50,
                     MotionDetectorEventWatchLook, NULL);
  CHECK(looks == 0, "stationary wrist raise must not look without walking");

  motion_detector_reset(&detector);
  now = 0;
  feed_pose(&detector, &now, 0, 1000, 0, 10,
            MotionDetectorEventNone, NULL);
  for (int i = 0; i < 3; i++) {
    feed(&detector, &now, 0, 1400, 0, false);
  }
  feed_pose(&detector, &now, 0, 1000, 0, 40,
            MotionDetectorEventNone, NULL);
  CHECK(detector.state == MotionDetectorIdle,
        "closely spaced bumps must not count as walking");
}

static void test_walk_to_look(void) {
  MotionDetector detector;
  uint32_t now = 0;
  motion_detector_reset(&detector);
  feed_pose(&detector, &now, 0, 1000, 0, 10,
            MotionDetectorEventNone, NULL);
  int walking = feed_walking_y(&detector, &now, 35, false);
  CHECK(walking == 1, "three cadence peaks must confirm one walking episode");

  uint32_t raised_started = now;
  uint32_t look_time = 0;
  int looks = feed_pose(&detector, &now, 0, 0, 1000, 50,
                        MotionDetectorEventWatchLook, &look_time);
  CHECK(looks == 1, "walking then a stable raised wrist must emit one look");
  CHECK(look_time >= raised_started && look_time - raised_started <= 600,
        "look must be confirmed within 600ms of the stable raised pose");
  looks += feed_pose(&detector, &now, 0, 0, 1000, 25,
                     MotionDetectorEventWatchLook, NULL);
  CHECK(looks == 1, "held watch pose must not emit repeated look events");
}

static void test_short_walk_vibration_and_candidate_timeout(void) {
  MotionDetector detector;
  uint32_t now = 0;
  motion_detector_reset(&detector);
  feed_pose(&detector, &now, 0, 1000, 0, 10,
            MotionDetectorEventNone, NULL);
  feed_walking_y(&detector, &now, 20, false);
  int looks = feed_pose(&detector, &now, 0, 0, 1000, 50,
                        MotionDetectorEventWatchLook, NULL);
  CHECK(looks == 0, "two walking peaks must not arm watch-look detection");

  motion_detector_reset(&detector);
  now = 0;
  feed_pose(&detector, &now, 0, 1000, 0, 10,
            MotionDetectorEventNone, NULL);
  int walking = feed_walking_y(&detector, &now, 40, true);
  CHECK(walking == 0, "vibration-contaminated peaks must be ignored");

  motion_detector_reset(&detector);
  now = 0;
  feed_pose(&detector, &now, 0, 1000, 0, 10,
            MotionDetectorEventNone, NULL);
  feed_walking_y(&detector, &now, 35, false);
  looks = feed_pose(&detector, &now, 0, 0, 1000, 12,
                    MotionDetectorEventWatchLook, NULL);
  looks += feed_pose(&detector, &now, 0, 1000, 0, 50,
                     MotionDetectorEventWatchLook, NULL);
  CHECK(looks == 0, "an unstable raise must expire without a look event");
  CHECK(!detector.walk_episode_active && !detector.baseline_valid,
        "an expired candidate must require a fresh walking episode");
}

static void test_rearm_after_second_walk(void) {
  MotionDetector detector;
  uint32_t now = 0;
  motion_detector_reset(&detector);
  feed_pose(&detector, &now, 0, 1000, 0, 10,
            MotionDetectorEventNone, NULL);
  feed_walking_y(&detector, &now, 35, false);
  int looks = feed_pose(&detector, &now, 0, 0, 1000, 50,
                        MotionDetectorEventWatchLook, NULL);
  int walking = feed_walking_z(&detector, &now, 35);
  CHECK(walking == 1, "a new cadence must rearm after the first watch look");
  looks += feed_pose(&detector, &now, 1000, 0, 0, 50,
                     MotionDetectorEventWatchLook, NULL);
  CHECK(looks == 2, "a second walking episode must permit one new look");
}

static int smoothing_ticks(int32_t start, int32_t target, bool fast) {
  int ticks = 0;
  int32_t current = start;
  while (current != target && ticks < 100) {
    current = bearing_smoothing_advance(current, target, fast);
    ticks++;
  }
  return ticks;
}

static void test_bearing_profiles(void) {
  CHECK(bearing_smoothing_step_centi_degrees(100, false) == 400,
        "normal profile must retain its four-degree minimum");
  CHECK(bearing_smoothing_step_centi_degrees(30000, false) == 1200,
        "normal profile must retain its twelve-degree cap");
  CHECK(bearing_smoothing_step_centi_degrees(100, true) == 800,
        "fast profile must use an eight-degree minimum");
  CHECK(bearing_smoothing_step_centi_degrees(30000, true) == 2400,
        "fast profile must use a twenty-four-degree cap");
  CHECK(bearing_smoothing_shortest_delta(35900, 100) == 200,
        "bearing must cross zero clockwise by the shortest path");
  CHECK(bearing_smoothing_shortest_delta(100, 35900) == -200,
        "bearing must cross zero counter-clockwise by the shortest path");

  int fast_ticks = smoothing_ticks(0, 18000, true);
  int normal_ticks = smoothing_ticks(0, 18000, false);
  CHECK(fast_ticks > 1 && fast_ticks <= 8,
        "fast 180-degree rotation must animate and finish within 240ms");
  CHECK(normal_ticks > fast_ticks,
        "normal rotation must remain slower than reacquisition");

  int32_t changed_target = 0;
  for (int i = 0; i < 3; i++) {
    changed_target = bearing_smoothing_advance(changed_target, 18000, true);
  }
  int changed_ticks = 0;
  while (changed_target != 27000 && changed_ticks < 20) {
    changed_target = bearing_smoothing_advance(changed_target, 27000, true);
    changed_ticks++;
  }
  CHECK(changed_target == 27000 && changed_ticks <= 8,
        "fast profile must accept a fresh target during reacquisition");

  int32_t one_tick = bearing_smoothing_advance_ticks(0, 18000, false, 1);
  int32_t four_ticks = bearing_smoothing_advance_ticks(0, 18000, false, 4);
  CHECK(one_tick == bearing_smoothing_advance(0, 18000, false),
        "one elapsed virtual tick must preserve the existing profile");
  CHECK(four_ticks != 18000 &&
            bearing_smoothing_shortest_delta(four_ticks, 18000) <
                bearing_smoothing_shortest_delta(one_tick, 18000),
        "four delayed virtual ticks must catch up without snapping");
  CHECK(bearing_smoothing_advance_ticks(0, 18000, true, 4) != 18000,
        "the four-tick catch-up cap must preserve two displayed fast frames");
  CHECK(bearing_smoothing_advance_ticks(35900, 100, false, 4) == 100,
        "elapsed catch-up must retain shortest-path wraparound");

  uint32_t elapsed_remainder = 0;
  CHECK(bearing_smoothing_consume_elapsed_ticks(
            &elapsed_remainder, 29, 30, 4) == 0 && elapsed_remainder == 29,
        "sub-tick elapsed bearing time must be retained");
  CHECK(bearing_smoothing_consume_elapsed_ticks(
            &elapsed_remainder, 1, 30, 4) == 1 && elapsed_remainder == 0,
        "retained fractional time must produce the next virtual tick");
  CHECK(bearing_smoothing_consume_elapsed_ticks(
            &elapsed_remainder, 200, 30, 4) == 4 && elapsed_remainder == 80,
        "catch-up capping must retain rather than discard excess backlog");
  CHECK(bearing_smoothing_consume_elapsed_ticks(
            &elapsed_remainder, 10, 30, 4) == 3 && elapsed_remainder == 0,
        "retained catch-up backlog must drain on the next displayed frame");
}

int main(void) {
  test_csv_fixtures();
  test_idle_and_false_raises();
  test_walk_to_look();
  test_short_walk_vibration_and_candidate_timeout();
  test_rearm_after_second_walk();
  test_bearing_profiles();
  if (s_failures != 0) {
    fprintf(stderr, "motion detector tests: %d failure(s)\n", s_failures);
    return 1;
  }
  printf("motion detector tests: all checks passed\n");
  return 0;
}
