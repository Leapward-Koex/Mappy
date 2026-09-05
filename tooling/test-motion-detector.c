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
  CHECK(bearing_smoothing_step_centi_degrees(100, false) == 25,
        "normal profile must interpolate ordinary one-degree sensor updates");
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
  int32_t wrapped = bearing_smoothing_advance_ticks(35900, 100, false, 4);
  CHECK(wrapped != 100 &&
            bearing_smoothing_shortest_delta(35900, wrapped) > 0 &&
            bearing_smoothing_shortest_delta(wrapped, 100) > 0,
        "elapsed catch-up must interpolate across zero by the shortest path");

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

static void test_bearing_small_updates(void) {
  const int32_t starts[] = {0, 35900, 100};
  const int32_t targets[] = {200, 100, 35900};
  for (unsigned i = 0; i < sizeof(starts) / sizeof(starts[0]); i++) {
    int32_t current = starts[i];
    int32_t remaining = bearing_smoothing_shortest_delta(current, targets[i]);
    int ticks = 0;
    while (remaining != 0 && ticks < 20) {
      int32_t next = bearing_smoothing_advance(current, targets[i], false);
      int32_t step = bearing_smoothing_shortest_delta(current, next);
      CHECK((remaining > 0 && step > 0 && step <= remaining) ||
                (remaining < 0 && step < 0 && step >= remaining),
            "small compass updates must converge without overshoot or reversal");
      CHECK(abs(step) <= 50,
            "a two-degree sensor update must start with at most half a degree");
      CHECK(next >= 0 && next < 36000,
            "interpolated bearing must stay normalized through north");
      current = next;
      remaining = bearing_smoothing_shortest_delta(current, targets[i]);
      ticks++;
    }
    CHECK(remaining == 0 && ticks >= 4 && ticks <= 8,
          "two-degree updates must animate and settle within 240ms");
  }

  CHECK(bearing_smoothing_advance(0, 10, false) == 10 &&
            bearing_smoothing_advance(10, 0, false) == 0,
        "sub-quarter-degree tails must settle so an idle compass stops drawing");
  CHECK(bearing_smoothing_advance_ticks(100, 35900, false, 0) == 100,
        "no elapsed ticks must leave the displayed bearing unchanged");
  int32_t sequential = 35900;
  for (int i = 0; i < 4; i++) {
    sequential = bearing_smoothing_advance(sequential, 100, false);
  }
  CHECK(bearing_smoothing_advance_ticks(35900, 100, false, 4) == sequential,
        "delayed frames must match the same elapsed small-angle filter steps");
}

static void test_bearing_sensor_stream(void) {
  // 30 degrees/second, with a quantized sensor event every 100ms and a 30ms
  // render tick. Begin just west of north to also exercise a streamed wrap.
  int32_t current = 35000;
  int32_t target = current;
  int changed_frames = 0;
  int32_t max_lag = 0;
  for (int tick = 0; tick < 100; tick++) {
    int sensor_events = tick * 30 / 100 + 1;
    target = (35000 + sensor_events * 300) % 36000;
    int32_t next = bearing_smoothing_advance(current, target, false);
    int32_t step = bearing_smoothing_shortest_delta(current, next);
    CHECK(step > 0 && step < 200,
          "streamed sensor motion must advance in small clockwise frames");
    if (next != current) {
      changed_frames++;
    }
    current = next;
    int32_t lag = bearing_smoothing_shortest_delta(current, target);
    if (lag > max_lag) {
      max_lag = lag;
    }
  }
  CHECK(changed_frames == 100,
        "30 sensor events must keep all 100 render ticks visibly advancing");
  CHECK(max_lag <= 400,
        "ordinary turns must stay within four degrees of the latest sensor");
  CHECK(smoothing_ticks(current, target, false) <= 8,
        "the display must settle promptly after a streamed turn stops");

  // Alternating one-degree noise at each tick should be attenuated around
  // north instead of turning into a two-degree display jump on every sample.
  current = 0;
  for (int tick = 0; tick < 60; tick++) {
    target = tick % 2 == 0 ? 100 : 35900;
    current = bearing_smoothing_advance(current, target, false);
    CHECK(abs(bearing_smoothing_shortest_delta(0, current)) <= 25,
          "alternating compass jitter must remain within a quarter degree");
  }
}

static int32_t normalize_test_bearing(int32_t angle) {
  angle %= 36000;
  return angle < 0 ? angle + 36000 : angle;
}

static void test_adaptive_bearing_metrics(void) {
  const int rates[] = {3000, 9000, -9000};
  for (unsigned rate = 0; rate < sizeof(rates) / sizeof(rates[0]); rate++) {
    BearingSmoothingAdaptive state = {0};
    int32_t baseline = 35000;
    int32_t adaptive = baseline;
    int32_t target = baseline;
    int32_t old_lag = 0;
    int32_t new_lag = 0;
    int measured = 0;
    int moving_frames = 0;
    bearing_smoothing_adaptive_observe(&state, target, 0);
    // Independent 10Hz sensor and 30ms render clocks, crossing north in both
    // directions. Compare lag to the same held sensor value after warm-up.
    for (uint32_t now = 10; now <= 3000; now += 10) {
      if (now % 100 == 0) {
        target = normalize_test_bearing(35000 + rates[rate] * (int32_t)now / 1000);
        bearing_smoothing_adaptive_observe(&state, target, now);
      }
      if (now % 30 == 0) {
        baseline = bearing_smoothing_advance(baseline, target, false);
        int32_t previous = adaptive;
        adaptive = bearing_smoothing_adaptive_advance_ticks(
            &state, adaptive, target, false, 1, now);
        if (now >= 600) {
          old_lag += abs(bearing_smoothing_shortest_delta(baseline, target));
          new_lag += abs(bearing_smoothing_shortest_delta(adaptive, target));
          measured++;
          moving_frames += previous != adaptive;
        }
      }
    }
    printf("bearing turn rate=%dcd/s old_mean_lag=%ldcd adaptive_mean_lag=%ldcd frames=%d/%d\n",
           rates[rate], (long)(old_lag / measured),
           (long)(new_lag / measured), moving_frames, measured);
    CHECK(new_lag * 100 <= old_lag * 65,
          "adaptive filter must cut sustained turn lag by at least 35 percent");
    CHECK(moving_frames == measured,
          "adaptive turns must retain changing intermediate render frames");
  }

  BearingSmoothingAdaptive state = {0};
  int32_t baseline = 0;
  int32_t adaptive = 0;
  int32_t target = 0;
  int32_t old_jitter = 0;
  int32_t new_jitter = 0;
  int measured = 0;
  bearing_smoothing_adaptive_observe(&state, target, 0);
  for (uint32_t now = 10; now <= 3000; now += 10) {
    if (now % 100 == 0) {
      target = now % 200 == 0 ? 100 : 35900;
      bearing_smoothing_adaptive_observe(&state, target, now);
    }
    if (now % 30 == 0) {
      baseline = bearing_smoothing_advance(baseline, target, false);
      adaptive = bearing_smoothing_adaptive_advance_ticks(
          &state, adaptive, target, false, 1, now);
      if (now >= 600) {
        old_jitter += abs(bearing_smoothing_shortest_delta(0, baseline));
        new_jitter += abs(bearing_smoothing_shortest_delta(0, adaptive));
        measured++;
      }
    }
  }
  printf("bearing jitter old_mean=%ldcd adaptive_mean=%ldcd\n",
         (long)(old_jitter / measured), (long)(new_jitter / measured));
  CHECK(new_jitter * 100 <= old_jitter * 75,
        "adaptive rest filtering must reduce compass jitter by at least 25 percent");

  bearing_smoothing_adaptive_reset(&state);
  bearing_smoothing_adaptive_observe(&state, 0, 0);
  bearing_smoothing_adaptive_observe(&state, 9000, 100);
  baseline = 0;
  adaptive = 0;
  int old_t90 = 0;
  int new_t90 = 0;
  for (uint32_t now = 130; now <= 1300; now += 30) {
    baseline = bearing_smoothing_advance(baseline, 9000, false);
    adaptive = bearing_smoothing_adaptive_advance_ticks(
        &state, adaptive, 9000, false, 1, now);
    if (!old_t90 && baseline >= 8100) old_t90 = (int)now - 100;
    if (!new_t90 && adaptive >= 8100) new_t90 = (int)now - 100;
  }
  printf("bearing 90deg step old_t90=%dms adaptive_t90=%dms\n", old_t90, new_t90);
  CHECK(new_t90 > 30 && new_t90 < old_t90,
        "a deliberate large turn must approach its target sooner without snapping");
  bearing_smoothing_adaptive_reset(&state);
  for (int mode = 0; mode < 2; mode++) {
    if (mode == 1) {
      bearing_smoothing_adaptive_observe(&state, 0, 0);
      bearing_smoothing_adaptive_observe(&state, 9000, 2000);
    }
    adaptive = 0;
    int t90 = 0;
    for (uint32_t elapsed = 30; elapsed <= 1200; elapsed += 30) {
      int32_t next = bearing_smoothing_adaptive_advance_ticks(
          &state, adaptive, 9000, false, 1, 2000 + elapsed);
      CHECK(next > adaptive || next == 9000,
            "large first-sample errors must converge monotonically");
      CHECK(next <= 9000 && next - adaptive <= 1200,
            "first and stale samples must retain the step cap without overshoot");
      adaptive = next;
      if (!t90 && adaptive >= 8100) t90 = (int)elapsed;
    }
    printf("bearing %s 90deg step adaptive_t90=%dms\n",
           mode == 0 ? "uninitialized" : "long-gap", t90);
    CHECK(t90 > 30 && t90 <= 240 && t90 < old_t90,
          "a first or long-gap turn must catch up promptly without a speed estimate");
  }
}

static void test_adaptive_bearing_clock_and_reset(void) {
  BearingSmoothingAdaptive rapid = {0};
  BearingSmoothingAdaptive slow = {0};
  bearing_smoothing_adaptive_observe(&rapid, 35900, 100);
  bearing_smoothing_adaptive_observe(&slow, 35900, 100);
  bearing_smoothing_adaptive_observe(&rapid, 100, 120);
  bearing_smoothing_adaptive_observe(&slow, 100, 300);
  CHECK(rapid.velocity_centi_per_second > slow.velocity_centi_per_second &&
            slow.velocity_centi_per_second > 0,
        "angular velocity must use actual sensor dt and clockwise wraparound");
  uint32_t sampled_at = rapid.sampled_at_ms;
  int32_t velocity = rapid.velocity_centi_per_second;
  for (uint32_t now = 150; now <= 600; now += 30) {
    bearing_smoothing_adaptive_observe(&rapid, 100, now);
  }
  CHECK(rapid.sampled_at_ms == sampled_at &&
            rapid.velocity_centi_per_second == velocity,
        "a held target must not manufacture new sensor samples on render ticks");
  int32_t stale = bearing_smoothing_adaptive_advance_ticks(
      &rapid, 0, 100, false, 1, 1000);
  BearingSmoothingAdaptive empty = {0};
  CHECK(stale == bearing_smoothing_adaptive_advance_ticks(
            &empty, 0, 100, false, 1, 1000),
        "stale turning velocity must not amplify later stationary jitter");
  bearing_smoothing_adaptive_observe(&rapid, -1, 1001);
  CHECK(!rapid.valid && rapid.velocity_centi_per_second == 0,
        "invalid heading must discard sensor history");
  bearing_smoothing_adaptive_observe(&rapid, 18000, 1010);
  CHECK(rapid.valid && rapid.velocity_centi_per_second == 0,
        "first heading after invalidation must not infer a synthetic turn");
  bearing_smoothing_adaptive_observe(&rapid, 19000, 1010);
  CHECK(rapid.sampled_at_ms == 1010 && rapid.heading_centi == 19000,
        "same-millisecond sensor bursts must not divide by zero or spike speed");
  bearing_smoothing_adaptive_observe(&rapid, 20000, 2200);
  CHECK(rapid.velocity_centi_per_second == 0,
        "a long sensor gap must reset the old motion estimate");

  bearing_smoothing_adaptive_reset(&rapid);
  bearing_smoothing_adaptive_observe(&rapid, 100, UINT32_MAX - 20);
  bearing_smoothing_adaptive_observe(&rapid, 35900, 20);
  CHECK(rapid.velocity_centi_per_second < 0,
        "sensor timestamp wrap must preserve counter-clockwise velocity");
  int32_t batched = bearing_smoothing_adaptive_advance_ticks(
      &rapid, 100, 35900, false, 4, 140);
  int32_t sequential = 100;
  for (int tick = 0; tick < 4; tick++) {
    sequential = bearing_smoothing_adaptive_advance_ticks(
        &rapid, sequential, 35900, false, 1, 140);
  }
  CHECK(batched == sequential,
        "adaptive delayed frames must consume the same virtual filter steps");
  CHECK(bearing_smoothing_adaptive_advance_ticks(
            &rapid, 0, 18000, true, 4, 140) ==
            bearing_smoothing_advance_ticks(0, 18000, true, 4),
        "speed adaptation must leave fast reacquisition unchanged");
  int32_t current = 0;
  int ticks = 0;
  while (current != 100 && ticks++ < 30) {
    current = bearing_smoothing_adaptive_advance_ticks(
        &empty, current, 100, false, 1, (uint32_t)ticks * 30);
  }
  CHECK(current == 100 && ticks < 20,
        "quiet small-angle tails must settle instead of drawing forever");
}
static void test_adaptive_irregular_turn_and_stop(void) {
  const uint32_t intervals[] = {50, 150, 80, 120};
  BearingSmoothingAdaptive state = {0};
  int32_t baseline = 35000;
  int32_t adaptive = baseline;
  int32_t target = baseline;
  int32_t old_error = 0;
  int32_t new_error = 0;
  uint32_t next_sample = 50;
  int sample = 1;
  int measured = 0;
  bearing_smoothing_adaptive_observe(&state, target, 0);
  for (uint32_t now = 10; now <= 2700; now += 10) {
    if (now == next_sample) {
      // Turn at 90deg/s, reverse after one second, then hold still.
      int32_t turn_ms = now < 1000 ? (int32_t)now :
          now < 2000 ? 2000 - (int32_t)now : 0;
      target = normalize_test_bearing(35000 + turn_ms * 9);
      bearing_smoothing_adaptive_observe(&state, target, now);
      next_sample += intervals[sample++ % 4];
    }
    if (now % 30 == 0) {
      baseline = bearing_smoothing_advance(baseline, target, false);
      int32_t remaining = bearing_smoothing_shortest_delta(adaptive, target);
      int32_t next = bearing_smoothing_adaptive_advance_ticks(
          &state, adaptive, target, false, 1, now);
      int32_t step = bearing_smoothing_shortest_delta(adaptive, next);
      CHECK(abs(step) <= abs(remaining) &&
                (step == 0 || (step > 0) == (remaining > 0)),
            "irregular samples and reversals must never overshoot the latest target");
      adaptive = next;
      if (now >= 600 && now <= 2100) {
        old_error += abs(bearing_smoothing_shortest_delta(baseline, target));
        new_error += abs(bearing_smoothing_shortest_delta(adaptive, target));
        measured++;
      }
    }
  }
  printf("bearing irregular reversal old_mean_lag=%ldcd adaptive_mean_lag=%ldcd\n",
         (long)(old_error / measured), (long)(new_error / measured));
  CHECK(new_error * 100 <= old_error * 65,
        "adaptive turns must reduce lag across irregular samples and reversals");
  CHECK(adaptive == target,
        "stopping after an irregular turn must settle exactly and stop animating");
}
int main(void) {
  test_csv_fixtures();
  test_idle_and_false_raises();
  test_walk_to_look();
  test_short_walk_vibration_and_candidate_timeout();
  test_rearm_after_second_walk();
  test_bearing_profiles();
  test_bearing_small_updates();
  test_bearing_sensor_stream();
  test_adaptive_bearing_metrics();
  test_adaptive_bearing_clock_and_reset();
  test_adaptive_irregular_turn_and_stop();
  if (s_failures != 0) {
    fprintf(stderr, "motion detector tests: %d failure(s)\n", s_failures);
    return 1;
  }
  printf("motion detector tests: all checks passed\n");
  return 0;
}
