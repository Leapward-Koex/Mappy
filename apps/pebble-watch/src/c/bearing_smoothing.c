#include "bearing_smoothing.h"

#define FULL_TURN 360000
#define MAX_SPEED 720000
#define PREDICTION_LIMIT 24000
#define MOTION_SPEED 15000

static int32_t magnitude(int32_t value) {
  return value < 0 ? -value : value;
}

static int32_t normalize(int32_t angle, int32_t turn) {
  angle %= turn;
  return angle < 0 ? angle + turn : angle;
}

static int32_t delta(int32_t from, int32_t to, int32_t turn) {
  int32_t result = normalize(to - from, turn);
  return result > turn / 2 ? result - turn : result;
}

static int32_t clamp(int32_t value, int32_t limit) {
  return value > limit ? limit : value < -limit ? -limit : value;
}

int32_t bearing_smoothing_shortest_delta(int32_t from_centi, int32_t to_centi) {
  return delta(from_centi, to_centi, 36000);
}

static uint32_t stale_after(const BearingTracker *state) {
  uint32_t deadline = state->sample_period_ms * 5 / 4;
  return deadline < 350 ? 350 : deadline;
}

static bool predicting(const BearingTracker *state, uint32_t now_ms) {
  return state->valid && state->has_sample && state->prediction_allowed &&
      state->directional_samples >= 2 &&
      magnitude(state->sensor_velocity_milli_per_second) >= MOTION_SPEED &&
      (state->sensor_velocity_milli_per_second > 0 ? 1 : -1) == state->direction &&
      now_ms - state->sampled_at_ms < stale_after(state) + 100;
}

static int32_t prediction(const BearingTracker *state, uint32_t now_ms) {
  if (!predicting(state, now_ms)) return 0;
  uint32_t age = now_ms - state->sampled_at_ms;
  // Extrapolate a turn with steadily decreasing reference velocity. Unlike a
  // hard lead clamp, this reaches the prediction boundary without a sudden
  // stop in the target. Slow turns use less than the 24-degree ceiling.
  uint32_t horizon = state->sample_period_ms * 2; // Period >=50ms, so H >=100ms.
  if (horizon > 500) horizon = 500;
  uint32_t bounded_horizon = PREDICTION_LIMIT * 2000 /
      magnitude(state->sensor_velocity_milli_per_second);
  if (horizon > bounded_horizon) horizon = bounded_horizon;
  uint32_t progress = age < horizon ? age : horizon;
  int32_t lead = state->sensor_velocity_milli_per_second * (int32_t)progress / 1000;
  lead = lead * (int32_t)(2 * horizon - progress) / (int32_t)(2 * horizon);
  uint32_t deadline = stale_after(state);
  if (age > deadline) lead = lead * (int32_t)(deadline + 100 - age) / 100;
  return lead;
}

void bearing_tracker_reset(BearingTracker *state) {
  *state = (BearingTracker){0};
  state->sample_period_ms = 200;
  state->rest_blend_ms = 120;
}

void bearing_tracker_snap(BearingTracker *state, int32_t heading_centi,
                          uint32_t now_ms) {
  bearing_tracker_reset(state);
  if (heading_centi < 0) return;
  state->display_milli_degrees = normalize(heading_centi, 36000) * 10;
  state->target_milli_degrees = state->display_milli_degrees;
  state->advanced_at_ms = now_ms;
  state->valid = true;
}

int32_t bearing_tracker_display_centi_degrees(const BearingTracker *state) {
  return state->valid ? state->display_milli_degrees / 10 : -1;
}

int32_t bearing_tracker_velocity_centi_degrees_per_second(
    const BearingTracker *state) {
  return state->velocity_milli_per_second / 10;
}

int32_t bearing_tracker_prediction_centi_degrees(const BearingTracker *state,
                                                uint32_t now_ms) {
  return prediction(state, now_ms) / 10;
}

bool bearing_tracker_active(const BearingTracker *state, uint32_t now_ms) {
  return state->valid && (predicting(state, now_ms) ||
      state->velocity_milli_per_second != 0 ||
      state->display_milli_degrees != state->target_milli_degrees);
}

int32_t bearing_tracker_advance(BearingTracker *state, uint32_t now_ms) {
  if (!state->valid) return -1;
  uint32_t elapsed = now_ms - state->advanced_at_ms;
  state->advanced_at_ms = now_ms;
  // A backwards clock correction only rebases the anchor. Discard long-stall
  // backlog; replaying it on later frames creates a second visible catch-up.
  if (elapsed > INT32_MAX) elapsed = 0;
  if (elapsed > 120) elapsed = 120;
  uint32_t time = now_ms - elapsed;
  while (elapsed) {
    uint32_t dt = elapsed < 10 ? elapsed : 10;
    elapsed -= dt;
    time += dt;
    int32_t error = delta(state->display_milli_degrees,
                          state->target_milli_degrees, FULL_TURN);
    bool motion = state->has_sample &&
        magnitude(state->sensor_velocity_milli_per_second) >= MOTION_SPEED &&
        time - state->sampled_at_ms < stale_after(state);
    if (motion || magnitude(error) >= 6000) state->moving = true;
    if (magnitude(error) < 1000 &&
        magnitude(state->velocity_milli_per_second) < 5000) {
      if (!motion) state->moving = false;
      state->acquiring = false;
    }
    if (state->moving) {
      state->rest_blend_ms = 0;
    } else if (state->rest_blend_ms < 120) {
      uint32_t blend = state->rest_blend_ms + dt;
      state->rest_blend_ms = blend > 120 ? 120 : (uint8_t)blend;
    }
    // Preserve the non-predicting phone/calibration follower's response.
    bool acquiring = state->acquiring || !state->prediction_allowed;
    int32_t gain = acquiring ? 20 : 16;
    int32_t omega = gain - (gain - 10) * state->rest_blend_ms / 120;
    error = delta(state->display_milli_degrees,
        normalize(state->target_milli_degrees + prediction(state, time), FULL_TURN),
        FULL_TURN);
    // Critically damped position/velocity follower. Retargeting changes only
    // acceleration: it never snaps position or erases velocity between samples.
    // Limit requested speed to 1.5x observed motion during tracking. Braking
    // remains continuous when that limit falls; never clamp existing momentum
    // to a newly lower sensor estimate. Explicit acquisition keeps its fast cap.
    // Bounds (180deg error, 720deg/s, dt<=10ms) keep all products in int32.
    int32_t limit = MAX_SPEED;
    if (!acquiring && state->has_sample) {
      limit = magnitude(state->sensor_velocity_milli_per_second) * 3 / 2;
      if (limit < 90000) limit = 90000;
      if (limit > MAX_SPEED) limit = MAX_SPEED;
    }
    int32_t desired_velocity = clamp(error * omega / 2, limit);
    int32_t acceleration = 2 * omega *
        (desired_velocity - state->velocity_milli_per_second);
    state->velocity_milli_per_second = clamp(state->velocity_milli_per_second +
        acceleration * (int32_t)dt / 1000, MAX_SPEED);
    state->display_milli_degrees = normalize(state->display_milli_degrees +
        state->velocity_milli_per_second * (int32_t)dt / 1000, FULL_TURN);
    if (!predicting(state, time) && magnitude(delta(state->display_milli_degrees,
            state->target_milli_degrees, FULL_TURN)) <= 250 &&
        magnitude(state->velocity_milli_per_second) <= 1000) {
      state->display_milli_degrees = state->target_milli_degrees;
      state->velocity_milli_per_second = 0;
    }
  }
  return bearing_tracker_display_centi_degrees(state);
}

void bearing_tracker_request_acquisition(BearingTracker *state, uint32_t now_ms) {
  bearing_tracker_advance(state, now_ms);
  state->has_sample = false;
  state->sensor_velocity_milli_per_second = 0;
  state->directional_samples = 0;
  state->direction = 0;
  state->sample_period_ms = 200;
  state->moving = true;
  state->acquiring = true;
  state->rest_blend_ms = 0;
}

void bearing_tracker_set_target(BearingTracker *state, int32_t heading_centi,
                                uint32_t now_ms) {
  if (!state->valid || heading_centi < 0) {
    bearing_tracker_snap(state, heading_centi, now_ms);
    return;
  }
  bearing_tracker_request_acquisition(state, now_ms);
  state->target_milli_degrees = normalize(heading_centi, 36000) * 10;
}

void bearing_tracker_observe(BearingTracker *state, int32_t heading_centi,
                             uint32_t sampled_at_ms, bool allow_prediction) {
  if (heading_centi < 0) {
    bearing_tracker_reset(state);
    return;
  }
  if (!state->valid) bearing_tracker_snap(state, heading_centi, sampled_at_ms);
  bearing_tracker_advance(state, sampled_at_ms);
  int32_t target = normalize(heading_centi, 36000) * 10;
  uint32_t elapsed = sampled_at_ms - state->sampled_at_ms;
  // The SDK may omit identical headings at rest. A large correction after
  // silence reacquires quickly instead of inheriting the low tracking cap.
  if ((!state->has_sample || elapsed > 1000) &&
      magnitude(delta(state->display_milli_degrees, target, FULL_TURN)) >= 6000) {
    state->acquiring = true;
  }
  if (!state->has_sample || elapsed == 0 || elapsed > 1000) {
    state->sensor_velocity_milli_per_second = 0;
    state->directional_samples = 0;
    state->direction = 0;
    if (elapsed > 1000) state->sample_period_ms = 200;
  } else {
    int32_t velocity = clamp(delta(state->target_milli_degrees, target,
        FULL_TURN) * 1000 / (int32_t)elapsed, MAX_SPEED);
    // Estimate signed velocity at real callback timestamps. Drawing and camera
    // synchronization must never refresh this measurement history.
    state->sensor_velocity_milli_per_second +=
        (velocity - state->sensor_velocity_milli_per_second) * (int32_t)elapsed /
        (80 + (int32_t)elapsed);
    int8_t direction = magnitude(velocity) >= MOTION_SPEED ?
        (velocity > 0 ? 1 : -1) : 0;
    // A clear >=6-degree turn from rest can predict immediately. Smaller turns
    // need two agreeing intervals; an opposing reading during a turn revokes
    // prediction, including when the filtered derivative still points forward.
    state->directional_samples = direction == 0 ? 0 :
        direction != state->direction ?
        (state->direction == 0 && magnitude(delta(state->target_milli_degrees,
            target, FULL_TURN)) >= 6000 ? 2 : 1) : 2;
    state->direction = direction;
    if (direction) state->acquiring = false;
    // Quickly learn ordinary longer cadence; a single missed reading must not
    // make every subsequent stop wait for a newly inflated stale deadline.
    if (elapsed <= 500 || state->sample_period_ms < 300) {
      int32_t period = elapsed > state->sample_period_ms ? (int32_t)elapsed :
          state->sample_period_ms + ((int32_t)elapsed - state->sample_period_ms) / 8;
      state->sample_period_ms = period < 50 ? 50 : period > 500 ? 500 : period;
    }
  }
  state->target_milli_degrees = target;
  state->sampled_at_ms = sampled_at_ms;
  state->has_sample = true;
  state->prediction_allowed = allow_prediction;
}
