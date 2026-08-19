#ifndef MAPPY_PAN_INERTIA_H
#define MAPPY_PAN_INERTIA_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  int32_t last_viewport_x;
  int32_t last_viewport_y;
  int32_t sample_viewport_x;
  int32_t sample_viewport_y;
  int32_t velocity_x_q8;
  int32_t velocity_y_q8;
  int16_t remainder_x_q8;
  int16_t remainder_y_q8;
  uint8_t pending_ms;
  uint8_t idle_ms;
  uint8_t elapsed_ms;
  uint8_t tick_count;
  bool has_velocity;
  bool active;
} PanInertiaState;

void pan_inertia_reset(PanInertiaState *state, int32_t viewport_x,
                       int32_t viewport_y);
void pan_inertia_observe(PanInertiaState *state, int32_t viewport_x,
                         int32_t viewport_y, uint32_t elapsed_ms);
bool pan_inertia_start(PanInertiaState *state);
bool pan_inertia_is_active(const PanInertiaState *state);
bool pan_inertia_advance(PanInertiaState *state, uint32_t elapsed_ms,
                         int32_t *viewport_x, int32_t *viewport_y);
void pan_inertia_cancel(PanInertiaState *state);

#endif
