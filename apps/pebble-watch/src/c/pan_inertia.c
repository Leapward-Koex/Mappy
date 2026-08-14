#include "pan_inertia.h"

#include <limits.h>
#include <string.h>

#define PAN_INERTIA_TICK_MS 30
#define PAN_INERTIA_COMBINE_MS 8
#define PAN_INERTIA_HISTORY_GAP_MS 120
#define PAN_INERTIA_RELEASE_IDLE_MS 80
#define PAN_INERTIA_START_SPEED_Q8 (2 * 256)
#define PAN_INERTIA_MAX_SPEED_Q8 (14 * 256)
#define PAN_INERTIA_STOP_SPEED_Q8 (256 / 2)
#define PAN_INERTIA_DECAY_Q8 208
#define PAN_INERTIA_MAX_TICKS 12

static uint8_t capped_elapsed_ms(uint8_t current, uint32_t elapsed_ms,
                                 uint8_t cap) {
  if (current >= cap || elapsed_ms >= (uint32_t)(cap - current)) {
    return cap;
  }
  return (uint8_t)(current + elapsed_ms);
}

static int32_t clamp_i64_to_i32(int64_t value) {
  if (value > INT32_MAX) {
    return INT32_MAX;
  }
  if (value < INT32_MIN) {
    return INT32_MIN;
  }
  return (int32_t)value;
}

static int32_t saturating_add_i32(int32_t value, int32_t delta) {
  if (delta > 0 && value > INT32_MAX - delta) {
    return INT32_MAX;
  }
  if (delta < 0 && value < INT32_MIN - delta) {
    return INT32_MIN;
  }
  return value + delta;
}

static uint32_t abs_i32_u(int32_t value) {
  return value < 0 ? (uint32_t)(-(int64_t)value) : (uint32_t)value;
}

static uint32_t approximate_speed_q8(int32_t x_q8, int32_t y_q8) {
  uint32_t x = abs_i32_u(x_q8);
  uint32_t y = abs_i32_u(y_q8);
  uint32_t maximum = x > y ? x : y;
  uint32_t minimum = x > y ? y : x;
  return maximum + minimum / 2;
}

static void clear_velocity_history(PanInertiaState *state) {
  state->sample_viewport_x = state->last_viewport_x;
  state->sample_viewport_y = state->last_viewport_y;
  state->pending_ms = 0;
  state->velocity_x_q8 = 0;
  state->velocity_y_q8 = 0;
  state->has_velocity = false;
}

static int32_t sample_velocity_q8(int64_t displacement,
                                  uint32_t elapsed_ms) {
  int64_t scaled = displacement * PAN_INERTIA_TICK_MS * 256;
  return clamp_i64_to_i32(scaled / elapsed_ms);
}

static int32_t ema_velocity_q8(int32_t old_q8, int32_t newest_q8) {
  return (int32_t)(((int64_t)old_q8 + (int64_t)newest_q8 * 3) / 4);
}

static void finish(PanInertiaState *state) {
  state->active = false;
  state->elapsed_ms = 0;
  state->velocity_x_q8 = 0;
  state->velocity_y_q8 = 0;
  state->remainder_x_q8 = 0;
  state->remainder_y_q8 = 0;
  state->has_velocity = false;
}

void pan_inertia_reset(PanInertiaState *state, int32_t viewport_x,
                       int32_t viewport_y) {
  if (!state) {
    return;
  }
  memset(state, 0, sizeof(*state));
  state->last_viewport_x = viewport_x;
  state->last_viewport_y = viewport_y;
  state->sample_viewport_x = viewport_x;
  state->sample_viewport_y = viewport_y;
}

void pan_inertia_observe(PanInertiaState *state, int32_t viewport_x,
                         int32_t viewport_y, uint32_t elapsed_ms) {
  if (!state) {
    return;
  }

  bool moved = viewport_x != state->last_viewport_x ||
      viewport_y != state->last_viewport_y;
  state->last_viewport_x = viewport_x;
  state->last_viewport_y = viewport_y;
  state->idle_ms = moved ? 0 : capped_elapsed_ms(
      state->idle_ms, elapsed_ms, PAN_INERTIA_RELEASE_IDLE_MS + 1);

  if (elapsed_ms > PAN_INERTIA_HISTORY_GAP_MS) {
    clear_velocity_history(state);
    return;
  }

  uint32_t pending_ms = (uint32_t)state->pending_ms + elapsed_ms;
  if (pending_ms < PAN_INERTIA_COMBINE_MS) {
    state->pending_ms = (uint8_t)pending_ms;
    return;
  }

  int64_t dx = (int64_t)viewport_x - state->sample_viewport_x;
  int64_t dy = (int64_t)viewport_y - state->sample_viewport_y;
  int32_t newest_x_q8 = sample_velocity_q8(dx, pending_ms);
  int32_t newest_y_q8 = sample_velocity_q8(dy, pending_ms);
  state->sample_viewport_x = viewport_x;
  state->sample_viewport_y = viewport_y;
  state->pending_ms = 0;

  if (state->has_velocity) {
    state->velocity_x_q8 = ema_velocity_q8(state->velocity_x_q8,
                                           newest_x_q8);
    state->velocity_y_q8 = ema_velocity_q8(state->velocity_y_q8,
                                           newest_y_q8);
  } else {
    state->velocity_x_q8 = newest_x_q8;
    state->velocity_y_q8 = newest_y_q8;
    state->has_velocity = true;
  }
}

bool pan_inertia_start(PanInertiaState *state) {
  if (!state || !state->has_velocity ||
      state->idle_ms > PAN_INERTIA_RELEASE_IDLE_MS) {
    pan_inertia_cancel(state);
    return false;
  }

  uint32_t speed_q8 = approximate_speed_q8(state->velocity_x_q8,
                                            state->velocity_y_q8);
  if (speed_q8 < PAN_INERTIA_START_SPEED_Q8) {
    pan_inertia_cancel(state);
    return false;
  }
  if (speed_q8 > PAN_INERTIA_MAX_SPEED_Q8) {
    state->velocity_x_q8 = (int32_t)(
        (int64_t)state->velocity_x_q8 * PAN_INERTIA_MAX_SPEED_Q8 / speed_q8);
    state->velocity_y_q8 = (int32_t)(
        (int64_t)state->velocity_y_q8 * PAN_INERTIA_MAX_SPEED_Q8 / speed_q8);
  }

  state->sample_viewport_x = state->last_viewport_x;
  state->sample_viewport_y = state->last_viewport_y;
  state->pending_ms = 0;
  state->elapsed_ms = 0;
  state->tick_count = 0;
  state->remainder_x_q8 = 0;
  state->remainder_y_q8 = 0;
  state->active = true;
  return true;
}

bool pan_inertia_is_active(const PanInertiaState *state) {
  return state && state->active;
}

bool pan_inertia_advance(PanInertiaState *state, uint32_t elapsed_ms,
                         int32_t *viewport_x, int32_t *viewport_y) {
  if (!state || !state->active || !viewport_x || !viewport_y) {
    return false;
  }

  uint32_t remaining_ticks = PAN_INERTIA_MAX_TICKS - state->tick_count;
  uint32_t elapsed_to_finish = remaining_ticks * PAN_INERTIA_TICK_MS -
      state->elapsed_ms;
  uint32_t ready_ticks;
  if (elapsed_ms >= elapsed_to_finish) {
    ready_ticks = remaining_ticks;
    state->elapsed_ms = 0;
  } else {
    // This branch proves the sum is below the 360 ms coast bound, avoiding a
    // costly 64-bit divide in every scheduler callback.
    uint32_t total_elapsed_ms = state->elapsed_ms + elapsed_ms;
    ready_ticks = total_elapsed_ms / PAN_INERTIA_TICK_MS;
    state->elapsed_ms = (uint8_t)(
        total_elapsed_ms - ready_ticks * PAN_INERTIA_TICK_MS);
  }

  bool changed = false;
  while (ready_ticks-- > 0 && state->active) {
    int32_t accumulated_x = state->remainder_x_q8 + state->velocity_x_q8;
    int32_t accumulated_y = state->remainder_y_q8 + state->velocity_y_q8;
    int32_t dx = accumulated_x / 256;
    int32_t dy = accumulated_y / 256;
    state->remainder_x_q8 = (int16_t)(accumulated_x % 256);
    state->remainder_y_q8 = (int16_t)(accumulated_y % 256);

    int32_t next_x = saturating_add_i32(*viewport_x, dx);
    int32_t next_y = saturating_add_i32(*viewport_y, dy);
    changed = changed || next_x != *viewport_x || next_y != *viewport_y;
    *viewport_x = next_x;
    *viewport_y = next_y;

    state->velocity_x_q8 = (int32_t)(
        (int64_t)state->velocity_x_q8 * PAN_INERTIA_DECAY_Q8 / 256);
    state->velocity_y_q8 = (int32_t)(
        (int64_t)state->velocity_y_q8 * PAN_INERTIA_DECAY_Q8 / 256);
    state->tick_count++;
    if (state->tick_count >= PAN_INERTIA_MAX_TICKS ||
        approximate_speed_q8(state->velocity_x_q8,
                             state->velocity_y_q8) <
            PAN_INERTIA_STOP_SPEED_Q8) {
      finish(state);
    }
  }
  return changed;
}

void pan_inertia_cancel(PanInertiaState *state) {
  if (!state) {
    return;
  }
  clear_velocity_history(state);
  state->idle_ms = 0;
  state->elapsed_ms = 0;
  state->tick_count = 0;
  state->remainder_x_q8 = 0;
  state->remainder_y_q8 = 0;
  state->active = false;
}
