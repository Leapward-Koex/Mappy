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

static int32_t normalize_test_bearing(int32_t angle) {
  angle %= 36000;
  return angle < 0 ? angle + 36000 : angle;
}

// Frozen pre-rewrite normal filter reference. It intentionally retains the old
// sample-and-hold response so the sweep measures speed ripple, not just whether
// every rendered frame differs by one imperceptible centidegree.
typedef struct {
  int32_t display, target, velocity;
  uint32_t sampled_at;
} OldBearing;

static void old_observe(OldBearing *state, int32_t target, uint32_t now) {
  uint32_t dt = now - state->sampled_at;
  if (dt && dt <= 1000) {
    int32_t velocity = bearing_smoothing_shortest_delta(state->target, target) *
        1000 / (int32_t)dt;
    if (velocity > 72000) velocity = 72000;
    if (velocity < -72000) velocity = -72000;
    state->velocity += (velocity - state->velocity) * (int32_t)dt / (80 + (int32_t)dt);
  } else state->velocity = 0;
  state->target = target;
  state->sampled_at = now;
}

static void old_advance(OldBearing *state, uint32_t now) {
  uint32_t age = now - state->sampled_at;
  int32_t speed = age <= 500 ? abs(state->velocity) : 0;
  speed = speed * 100 / (100 + (int32_t)age);
  int32_t tau = 159000 / (1000 + (speed > 800 ? (speed - 800) * 3 / 2 : 0));
  if (tau < 10) tau = 10;
  int32_t alpha = 256 * 30 / (tau + 30);
  int32_t error = bearing_smoothing_shortest_delta(state->display, state->target);
  int32_t amount = abs(error);
  int32_t escape = amount > 600 ? 64 + (amount - 600) / 16 : 0;
  if (escape > 192) escape = 192;
  if (escape > alpha) alpha = escape;
  int32_t step = (amount * alpha + 128) / 256;
  if (step < 5) step = 5;
  if (step > 1200) step = 1200;
  state->display = amount <= step ? state->target :
      normalize_test_bearing(state->display + (error > 0 ? step : -step));
}

static void test_tracker_ramps(void) {
  const int periods[] = {50, 100, 200, 300};
  const int rates[] = {3000, 9000, 18000, -3000, -9000, -18000};
  for (unsigned p = 0; p < sizeof(periods) / sizeof(periods[0]); p++) {
    for (unsigned r = 0; r < sizeof(rates) / sizeof(rates[0]); r++) {
      BearingTracker state;
      bearing_tracker_reset(&state);
      bearing_tracker_observe(&state, 35000, 0, true);
      OldBearing old = {.display = 35000, .target = 35000};
      int32_t previous = 35000;
      int32_t min_speed = INT32_MAX, max_speed = 0;
      int32_t old_min = INT32_MAX, old_max = 0;
      int64_t lag = 0;
      int samples = 0, old_pauses = 0, pauses = 0, longest_pause = 0;
      for (uint32_t now = 10; now <= 4000; now += 10) {
        int32_t truth = normalize_test_bearing(35000 + rates[r] * (int32_t)now / 1000);
        if (now % periods[p] == 0) {
          bearing_tracker_observe(&state, truth, now, true);
          old_observe(&old, truth, now);
        }
        if (now % 30 != 0) continue;
        int32_t shown = bearing_tracker_advance(&state, now);
        int32_t old_previous = old.display;
        old_advance(&old, now);
        int32_t signed_step = bearing_smoothing_shortest_delta(previous, shown);
        int32_t speed = abs(signed_step) * 1000 / 30;
        int32_t old_speed = abs(bearing_smoothing_shortest_delta(old_previous, old.display)) * 1000 / 30;
        CHECK(shown >= 0 && shown < 36000, "streamed bearing stays normalized");
        CHECK((signed_step >= 0) == (rates[r] > 0) || signed_step == 0,
              "constant turns never reverse displayed direction");
        CHECK(abs(bearing_tracker_velocity_centi_degrees_per_second(&state)) <= 72000,
              "controller velocity remains bounded at 720 degrees per second");
        if (now >= 1000) {
          if (speed < min_speed) min_speed = speed;
          if (speed > max_speed) max_speed = speed;
          if (old_speed < old_min) old_min = old_speed;
          if (old_speed > old_max) old_max = old_speed;
          if (speed < abs(rates[r]) / 10) pauses += 30; else pauses = 0;
          if (pauses > longest_pause) longest_pause = pauses;
          old_pauses += old_speed < abs(rates[r]) / 10;
          lag += abs(bearing_smoothing_shortest_delta(shown, truth));
          samples++;
        }
        previous = shown;
      }
      printf("tracker ramp rate=%dcd/s sample=%dms speed=%ld..%ldcd/s lag=%lldms pause=%dms old_pauses=%d old_ripple=%ld new_ripple=%ld\n",
          rates[r], periods[p], (long)min_speed, (long)max_speed,
          (long long)(lag * 1000 / samples / abs(rates[r])), longest_pause,
          old_pauses, (long)(old_max - old_min), (long)(max_speed - min_speed));
      CHECK(max_speed - min_speed < old_max - old_min,
            "continuous tracking reduces measured speed ripple versus old filter");
      if (periods[p] <= 200) {
        CHECK(longest_pause < 60, "steady turns have no near-stop lasting 60ms");
        CHECK(min_speed >= abs(rates[r]) / 10 && max_speed <= abs(rates[r]) * 2,
              "steady 5Hz-or-faster speed remains between 0.1x and 2x true motion");
      }
    }
  }
}

static void test_tracker_steps_and_wrap(void) {
  CHECK(bearing_smoothing_shortest_delta(35900, 100) == 200 &&
        bearing_smoothing_shortest_delta(100, 35900) == -200,
        "heading deltas choose the shortest direction across north");
  const int32_t starts[] = {0, 0, 35900, 100};
  const int32_t changes[] = {9000, 18000, 200, -200};
  for (int i = 0; i < 4; i++) {
    BearingTracker state;
    bearing_tracker_snap(&state, starts[i], 0);
    int32_t target = normalize_test_bearing(starts[i] + changes[i]);
    bearing_tracker_observe(&state, target, 100, true);
    int32_t previous = starts[i];
    int t90 = 0;
    for (uint32_t elapsed = 10; elapsed <= 1000; elapsed += 10) {
      int32_t shown = bearing_tracker_advance(&state, 100 + elapsed);
      int32_t progress = bearing_smoothing_shortest_delta(starts[i], shown);
      int32_t step = bearing_smoothing_shortest_delta(previous, shown);
      CHECK(abs(progress) <= abs(changes[i]), "isolated steps do not overshoot");
      CHECK(step == 0 || (step > 0) == (changes[i] > 0),
            "isolated steps converge monotonically, including north wrap");
      CHECK(abs(state.velocity_milli_per_second) <= 720000,
            "large acquisition respects the speed limit");
      if (!t90 && abs(progress) * 10 >= abs(changes[i]) * 9) t90 = elapsed;
      previous = shown;
    }
    CHECK(previous == target && !bearing_tracker_active(&state, 1100),
          "isolated steps settle exactly and idle within one second");
    if (i < 2) {
      printf("tracker step=%ldcd t90=%dms\n", (long)changes[i], t90);
      CHECK(t90 > 30 && t90 <= (i == 0 ? 240 : 300),
            "90/180 degree acquisition meets 240/300ms t90 without snapping");
    }
  }
}

static void test_tracker_stop_and_reverse(void) {
  int worst_overshoot = 0, worst_idle = 0, worst_reverse = 0;
  const int rates[] = {9000, 18000, -9000, -18000};
  for (int r = 0; r < 4; r++) for (int phase = 0; phase < 200; phase += 50) {
    for (int reverse = 0; reverse < 2; reverse++) {
      BearingTracker state;
      bearing_tracker_reset(&state);
      bearing_tracker_observe(&state, 0, 0, true);
      int stop_at = 1000 + phase;
      int last_sample = 0, first_opposed = 0, reversed_at = 0, idle_at = 0;
      int final_heading = rates[r] * stop_at / 1000;
      int overshoot = 0, display_unwrapped = 0, previous_display = 0;
      for (int now = 10; now <= stop_at + 1500; now += 10) {
        int turn_time = now <= stop_at ? now : reverse ? 2 * stop_at - now : stop_at;
        int truth = normalize_test_bearing(rates[r] * turn_time / 1000);
        if (now % 200 == 0 && truth != last_sample) {
          int sample_delta = bearing_smoothing_shortest_delta(last_sample, truth);
          bool opposing = sample_delta != 0 && (sample_delta > 0) != (rates[r] > 0);
          if (opposing && !first_opposed) first_opposed = now;
          bearing_tracker_observe(&state, truth, now, true);
          if (opposing && first_opposed == now) {
            CHECK(bearing_tracker_prediction_centi_degrees(&state, now + 30) == 0,
                  "the first opposing sample immediately disables prediction");
          }
          last_sample = truth;
        }
        int display = bearing_tracker_advance(&state, now);
        display_unwrapped += bearing_smoothing_shortest_delta(previous_display, display);
        previous_display = display;
        if (now < stop_at) continue;
        int beyond = display_unwrapped - final_heading;
        if (rates[r] < 0) beyond = -beyond;
        if (beyond > overshoot) overshoot = beyond;
        if (first_opposed && !reversed_at &&
            (state.velocity_milli_per_second > 0) != (rates[r] > 0)) reversed_at = now;
        if (!reverse && !idle_at && !bearing_tracker_active(&state, now)) idle_at = now;
      }
      CHECK(overshoot <= 1000, "abrupt stop/reversal total display overshoot stays below ten degrees");
      if (overshoot > worst_overshoot) worst_overshoot = overshoot;
      if (reverse) {
        CHECK(reversed_at && reversed_at - first_opposed <= 150,
              "display velocity reverses within 150ms after first opposing sample");
        if (reversed_at - first_opposed > worst_reverse) worst_reverse = reversed_at - first_opposed;
      } else {
        CHECK(idle_at && idle_at - stop_at <= 1000, "stopped turns idle within one second");
        if (idle_at - stop_at > worst_idle) worst_idle = idle_at - stop_at;
      }
    }
  }
  printf("tracker stop/reverse max_overshoot=%dcd idle=%dms reverse_after_sample=%dms\n",
         worst_overshoot, worst_idle, worst_reverse);
}

static void test_tracker_jitter_and_history(void) {
  BearingTracker state;
  bearing_tracker_reset(&state);
  bearing_tracker_observe(&state, 0, 0, true);
  int total = 0, measured = 0, peak = 0;
  for (uint32_t now = 10; now <= 4000; now += 10) {
    if (now % 200 == 0) bearing_tracker_observe(&state, now % 400 ? 100 : 35900, now, true);
    if (now % 30 == 0) {
      int shown = bearing_tracker_advance(&state, now);
      if (now >= 1000) {
        int jitter = abs(bearing_smoothing_shortest_delta(0, shown));
        total += jitter;
        measured++;
        if (jitter > peak) peak = jitter;
      }
      CHECK(bearing_tracker_prediction_centi_degrees(&state, now) == 0,
            "alternating stationary noise never gains prediction confidence");
    }
  }
  printf("tracker stationary +/-1deg sample=200ms mean_jitter=%dcd peak=%dcd\n", total / measured, peak);
  CHECK(total <= measured * 30 && peak <= 60,
        "stationary 5Hz jitter stays below 0.3 degree mean and 0.6 degree peak");

  bearing_tracker_reset(&state);
  bearing_tracker_observe(&state, 35000, 0, true);
  bearing_tracker_observe(&state, 800, 200, true);
  CHECK(bearing_tracker_prediction_centi_degrees(&state, 250) == 0,
        "one directional delta is insufficient for prediction");
  bearing_tracker_observe(&state, 2600, 400, true);
  CHECK(bearing_tracker_prediction_centi_degrees(&state, 500) == 800,
        "two consistent turns predict up to eight degrees");
  uint32_t sample_time = state.sampled_at_ms;
  int32_t sensor_velocity = state.sensor_velocity_milli_per_second;
  for (uint32_t now = 430; now <= 700; now += 30) bearing_tracker_advance(&state, now);
  CHECK(state.sampled_at_ms == sample_time && state.sensor_velocity_milli_per_second == sensor_velocity,
        "render ticks do not create observations or decay sensor velocity between samples");
  CHECK(bearing_tracker_prediction_centi_degrees(&state, 700) == 800 &&
        bearing_tracker_prediction_centi_degrees(&state, 750) == 400 &&
        bearing_tracker_prediction_centi_degrees(&state, 800) == 0,
        "late prediction holds to stale deadline then fades over exactly 100ms");
  bearing_tracker_observe(&state, 2600, 720, true);
  CHECK(state.sampled_at_ms == 720 && state.directional_samples == 0,
        "an unchanged real sample refreshes timestamp and clears direction confidence");
  bearing_tracker_observe(&state, -1, 730, true);
  CHECK(!state.valid && !bearing_tracker_active(&state, 730),
        "invalid samples clear display and derivative state");
  bearing_tracker_observe(&state, 18000, 740, true);
  CHECK(state.valid && state.sensor_velocity_milli_per_second == 0 &&
        bearing_tracker_display_centi_degrees(&state) == 18000,
        "first valid heading seeds without inventing motion");
  bearing_tracker_observe(&state, 19000, 740, true);
  CHECK(state.target_milli_degrees == 190000 && state.directional_samples == 0,
        "same-millisecond callbacks coalesce latest raw heading without a derivative");
  bearing_tracker_observe(&state, 20000, 2000, true);
  CHECK(state.sensor_velocity_milli_per_second == 0 && state.sample_period_ms == 200,
        "long observation gaps reset sensor history and expected period");

  bearing_tracker_observe(&state, 21000, 2200, false);
  bearing_tracker_observe(&state, 22000, 2400, false);
  CHECK(bearing_tracker_prediction_centi_degrees(&state, 2500) == 0,
        "phone or explicitly disabled prediction never extrapolates");
}

static void test_tracker_event_clock(void) {
  BearingTracker event_first, render_first;
  bearing_tracker_snap(&event_first, 0, 0);
  bearing_tracker_observe(&event_first, 9000, 0, true);
  render_first = event_first;
  // Retarget after 70ms with no intervening render. Integrating the old state
  // before the callback must equal explicitly rendering up to its arrival.
  bearing_tracker_advance(&render_first, 70);
  int32_t position = render_first.display_milli_degrees;
  int32_t velocity = render_first.velocity_milli_per_second;
  bearing_tracker_observe(&event_first, 18000, 70, true);
  bearing_tracker_observe(&render_first, 18000, 70, true);
  CHECK(event_first.display_milli_degrees == position &&
        event_first.velocity_milli_per_second == velocity,
        "retargeting preserves elapsed old trajectory position and velocity");
  CHECK(bearing_tracker_advance(&event_first, 100) == bearing_tracker_advance(&render_first, 100),
        "callback-before-render cannot apply a fresh target retroactively");
  position = event_first.display_milli_degrees;
  velocity = event_first.velocity_milli_per_second;
  bearing_tracker_request_acquisition(&event_first, 100);
  CHECK(event_first.display_milli_degrees == position && event_first.velocity_milli_per_second == velocity &&
        !event_first.has_sample && event_first.directional_samples == 0,
        "one-time acquisition resets prediction without resetting display momentum");
  bearing_tracker_set_target(&event_first, 1000, 100);
  CHECK(event_first.display_milli_degrees == position && event_first.velocity_milli_per_second == velocity &&
        !event_first.has_sample,
        "declination retargets preserve display state and are not sensor samples");

  bearing_tracker_snap(&event_first, 0, 0);
  bearing_tracker_observe(&event_first, 18000, 0, true);
  render_first = event_first;
  bearing_tracker_advance(&event_first, 1000);
  bearing_tracker_advance(&render_first, 120);
  CHECK(event_first.display_milli_degrees == render_first.display_milli_degrees,
        "long render stalls consume at most 120ms of controller time");
  bearing_tracker_advance(&event_first, 1010);
  bearing_tracker_advance(&render_first, 130);
  CHECK(event_first.display_milli_degrees == render_first.display_milli_degrees,
        "discarded render backlog does not reappear on the next frame");
  position = event_first.display_milli_degrees;
  bearing_tracker_advance(&event_first, 900);
  CHECK(event_first.display_milli_degrees == position,
        "backward clock correction only rebases the integration anchor");

  bearing_tracker_reset(&event_first);
  bearing_tracker_observe(&event_first, 100, UINT32_MAX - 20, true);
  bearing_tracker_observe(&event_first, 35900, 20, true);
  CHECK(event_first.sensor_velocity_milli_per_second < 0,
        "timestamp wrap preserves real counter-clockwise sensor velocity");
  CHECK(event_first.sample_period_ms >= 50 && event_first.sample_period_ms <= 300,
        "sample period estimate remains bounded");
  bearing_tracker_snap(&event_first, 12300, 100);
  CHECK(!event_first.has_sample && event_first.velocity_milli_per_second == 0 &&
        !bearing_tracker_active(&event_first, 100),
        "explicit menu resume snap clears momentum and sensor history");
}

static void test_tracker_irregular_and_first_motion(void) {
  BearingTracker state;
  bearing_tracker_reset(&state);
  bearing_tracker_observe(&state, 0, 0, false);
  bearing_tracker_observe(&state, 200, 50, false);
  bearing_tracker_advance(&state, 60);
  CHECK(state.moving && state.rest_blend_ms == 0 && state.directional_samples == 1,
        "fresh small turns use moving gain before prediction qualifies, even when prediction is disabled");
  CHECK(bearing_tracker_prediction_centi_degrees(&state, 80) == 0,
        "moving controller gain does not imply permission to predict");

  // Non-round callback timestamps ensure partial integration steps and render
  // ordering are exercised; the 293ms gap also spans the calibrated 5Hz cadence.
  const uint32_t gaps[] = {53, 197, 107, 293};
  bearing_tracker_reset(&state);
  bearing_tracker_observe(&state, 35000, 0, true);
  uint32_t next_sample = gaps[0];
  int sample = 1;
  int32_t last_sample = 35000;
  for (uint32_t now = 1; now <= 3500; now++) {
    if (now == next_sample) {
      int32_t turn_ms = now <= 1000 ? (int32_t)now :
          now < 2000 ? 2000 - (int32_t)now : 0;
      int32_t target = normalize_test_bearing(35000 + turn_ms * 9);
      if (target != last_sample) bearing_tracker_observe(&state, target, now, true);
      last_sample = target;
      next_sample += gaps[sample++ % 4];
    }
    if (now % 30 == 0) {
      uint32_t observed_at = state.sampled_at_ms;
      int32_t shown = bearing_tracker_advance(&state, now);
      CHECK(shown >= 0 && shown < 36000 && abs(state.velocity_milli_per_second) <= 720000,
            "irregular callback integration stays normalized and speed bounded");
      CHECK(abs(bearing_tracker_prediction_centi_degrees(&state, now)) <= 800 &&
            state.sampled_at_ms == observed_at,
            "irregular rendering bounds prediction without inventing observations");
    }
  }
  CHECK(bearing_tracker_display_centi_degrees(&state) == 35000 &&
        !bearing_tracker_active(&state, 3500),
        "irregular turn/reversal stream settles exactly after stopping");
}
int main(void) {
  test_csv_fixtures();
  test_idle_and_false_raises();
  test_walk_to_look();
  test_short_walk_vibration_and_candidate_timeout();
  test_rearm_after_second_walk();
  test_tracker_ramps();
  test_tracker_steps_and_wrap();
  test_tracker_stop_and_reverse();
  test_tracker_jitter_and_history();
  test_tracker_event_clock();
  test_tracker_irregular_and_first_motion();
  if (s_failures != 0) {
    fprintf(stderr, "motion detector tests: %d failure(s)\n", s_failures);
    return 1;
  }
  printf("motion detector tests: all checks passed\n");
  return 0;
}
