#include "bearing_smoothing.h"

#define FULL_TURN 360000
#define MAX_SPEED 720000
#define PREDICTION_LIMIT 8000
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
  uint32_t deadline = state->sample_period_ms * 3 / 2;
  return deadline < 300 ? 300 : deadline;
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
  int32_t lead = clamp(state->sensor_velocity_milli_per_second *
      (int32_t)(age < 100 ? age : 100) / 1000, PREDICTION_LIMIT);
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
    if (state->moving && !motion && magnitude(error) < 1000 &&
        magnitude(state->velocity_milli_per_second) < 5000) state->moving = false;
    if (state->moving) {
      state->rest_blend_ms = 0;
    } else if (state->rest_blend_ms < 120) {
      uint32_t blend = state->rest_blend_ms + dt;
      state->rest_blend_ms = blend > 120 ? 120 : (uint8_t)blend;
    }
    int32_t omega = 20 - state->rest_blend_ms / 12;
    error = delta(state->display_milli_degrees,
        normalize(state->target_milli_degrees + prediction(state, time), FULL_TURN),
        FULL_TURN);
    // Critically damped position/velocity follower. Retargeting changes only
    // acceleration: it never snaps position or erases velocity between samples.
    // Bounds (180deg error, 720deg/s, dt<=10ms) keep all products in int32.
    int32_t acceleration = omega * omega * error -
        2 * omega * state->velocity_milli_per_second;
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
  if (!state->has_sample || elapsed == 0 || elapsed > 1000) {
    state->sensor_velocity_milli_per_second = 0;
    state->directional_samples = 0;
    state->direction = 0;
    if (elapsed > 1000) state->sample_period_ms = 200;
  } else {
    int32_t velocity = clamp(delta(state->target_milli_degrees, target,
        FULL_TURN) * 1000 / (int32_t)elapsed, MAX_SPEED);
    // The 1 Euro filter's useful distinction is retained: estimate signed
    // velocity at real sensor timestamps; integrate displayed pose separately.
    state->sensor_velocity_milli_per_second +=
        (velocity - state->sensor_velocity_milli_per_second) * (int32_t)elapsed /
        (80 + (int32_t)elapsed);
    int8_t direction = magnitude(velocity) >= MOTION_SPEED ?
        (velocity > 0 ? 1 : -1) : 0;
    state->directional_samples = direction == 0 ? 0 :
        direction != state->direction ? 1 : 2;
    state->direction = direction;
    int32_t period = state->sample_period_ms +
        ((int32_t)elapsed - state->sample_period_ms) / 4;
    state->sample_period_ms = period < 50 ? 50 : period > 300 ? 300 : period;
  }
  state->target_milli_degrees = target;
  state->sampled_at_ms = sampled_at_ms;
  state->has_sample = true;
  state->prediction_allowed = allow_prediction;
}
