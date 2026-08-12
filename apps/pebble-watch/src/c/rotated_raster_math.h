#ifndef MAPPY_ROTATED_RASTER_MATH_H
#define MAPPY_ROTATED_RASTER_MATH_H

#include <stdbool.h>
#include <stdint.h>

// Pebble's trigonometric lookup functions use an odd 0xffff denominator.
// Keeping this value explicit makes the accumulator's rounding contract
// independent of a host test's SDK headers.
#define ROTATED_RASTER_TRIG_RATIO 65535
#define ROTATED_RASTER_TRIG_HALF 32767
#define ROTATED_RASTER_BLOCK_SIZE 8

typedef struct {
  int32_t rounded;
  uint16_t phase;
} RotatedRasterAccumulator;

typedef struct {
  int8_t whole;
  uint16_t phase;
} RotatedRasterStep;

typedef struct {
  RotatedRasterAccumulator x;
  RotatedRasterAccumulator y;
} RotatedRasterPoint;

typedef struct {
  RotatedRasterPoint row_origin;
  RotatedRasterStep pixel_x;
  RotatedRasterStep pixel_y;
  RotatedRasterStep row_x;
  RotatedRasterStep row_y;
} RotatedRasterDda;

typedef struct {
  int8_t pixel_dx;
  int8_t pixel_dy;
  int8_t row_dx;
  int8_t row_dy;
} RotatedRasterCardinal;

typedef struct {
  int32_t min_x;
  int32_t max_x;
  int32_t min_y;
  int32_t max_y;
} RotatedRasterBounds;

// Matches the existing sampled renderer's half-away-from-zero conversion.
// Rotated-map numerators are bounded to a few screen extents, so negating a
// negative numerator cannot encounter INT32_MIN.
static inline int32_t rotated_raster_round_nearest(int32_t numerator) {
  if (numerator >= 0) {
    return (numerator + ROTATED_RASTER_TRIG_HALF) /
        ROTATED_RASTER_TRIG_RATIO;
  }
  return -(((-numerator) + ROTATED_RASTER_TRIG_HALF) /
           ROTATED_RASTER_TRIG_RATIO);
}

// Return the exact axis-aligned world-delta bounds sampled by the framebuffer
// raster.  Screen coordinates are asymmetric for even dimensions: a 200-wide
// target centered at 100 samples [-100, 99], not [-100, 100].
static inline void rotated_raster_bounds_init(
    RotatedRasterBounds *bounds, int width, int height,
    int center_x, int center_y, int32_t sin_value, int32_t cos_value) {
  const int32_t left = -center_x;
  const int32_t right = width - 1 - center_x;
  const int32_t top = -center_y;
  const int32_t bottom = height - 1 - center_y;
  const int32_t corners[4][2] = {
    {left, top}, {right, top}, {right, bottom}, {left, bottom},
  };
  bounds->min_x = INT32_MAX;
  bounds->max_x = INT32_MIN;
  bounds->min_y = INT32_MAX;
  bounds->max_y = INT32_MIN;
  for (int i = 0; i < 4; i++) {
    int32_t sx = corners[i][0];
    int32_t sy = corners[i][1];
    int32_t world_x = rotated_raster_round_nearest(
        sx * cos_value - sy * sin_value);
    int32_t world_y = rotated_raster_round_nearest(
        sx * sin_value + sy * cos_value);
    if (world_x < bounds->min_x) bounds->min_x = world_x;
    if (world_x > bounds->max_x) bounds->max_x = world_x;
    if (world_y < bounds->min_y) bounds->min_y = world_y;
    if (world_y > bounds->max_y) bounds->max_y = world_y;
  }
}

// Invariant after initialization and every advance:
//   rounded = floor((numerator + 32767) / 65535)
//   phase = numerator + 32767 - rounded * 65535
//   0 <= phase < 65535
static inline void rotated_raster_accumulator_init(
    RotatedRasterAccumulator *accumulator, int32_t numerator) {
  accumulator->rounded = rotated_raster_round_nearest(numerator);
  accumulator->phase = (uint16_t)(
      numerator + ROTATED_RASTER_TRIG_HALF -
      accumulator->rounded * ROTATED_RASTER_TRIG_RATIO);
}

// Trig lookup values are in [-65535, 65535].  Decompose the step into a
// signed whole part and a non-negative modular phase so an advance needs at
// most one carry and never divides.
static inline void rotated_raster_step_init(RotatedRasterStep *step,
                                            int32_t numerator_delta) {
  if (numerator_delta >= ROTATED_RASTER_TRIG_RATIO) {
    step->whole = 1;
    step->phase = (uint16_t)(numerator_delta -
                             ROTATED_RASTER_TRIG_RATIO);
  } else if (numerator_delta < 0) {
    step->whole = -1;
    step->phase = (uint16_t)(numerator_delta +
                             ROTATED_RASTER_TRIG_RATIO);
  } else {
    step->whole = 0;
    step->phase = (uint16_t)numerator_delta;
  }
}

static inline int32_t rotated_raster_accumulator_advance(
    RotatedRasterAccumulator *accumulator,
    const RotatedRasterStep *step) {
  int32_t previous = accumulator->rounded;
  uint32_t phase = (uint32_t)accumulator->phase + step->phase;
  accumulator->rounded += step->whole;
  if (phase >= ROTATED_RASTER_TRIG_RATIO) {
    phase -= ROTATED_RASTER_TRIG_RATIO;
    accumulator->rounded++;
  }
  accumulator->phase = (uint16_t)phase;
  return accumulator->rounded - previous;
}

static inline void rotated_raster_point_advance(
    RotatedRasterPoint *point,
    const RotatedRasterStep *x_step,
    const RotatedRasterStep *y_step,
    int32_t *dx, int32_t *dy) {
  *dx = rotated_raster_accumulator_advance(&point->x, x_step);
  *dy = rotated_raster_accumulator_advance(&point->y, y_step);
}

static inline void rotated_raster_dda_init(RotatedRasterDda *dda,
                                           int center_x, int center_y,
                                           int32_t sin_value,
                                           int32_t cos_value) {
  int32_t sx = -center_x;
  int32_t sy = -center_y;
  rotated_raster_accumulator_init(
      &dda->row_origin.x, sx * cos_value - sy * sin_value);
  rotated_raster_accumulator_init(
      &dda->row_origin.y, sx * sin_value + sy * cos_value);
  rotated_raster_step_init(&dda->pixel_x, cos_value);
  rotated_raster_step_init(&dda->pixel_y, sin_value);
  rotated_raster_step_init(&dda->row_x, -sin_value);
  rotated_raster_step_init(&dda->row_y, cos_value);
}

static inline bool rotated_raster_cardinal_init(
    RotatedRasterCardinal *cardinal,
    int32_t sin_value, int32_t cos_value) {
  if (sin_value == 0 && cos_value == ROTATED_RASTER_TRIG_RATIO) {
    *cardinal = (RotatedRasterCardinal) {
      .pixel_dx = 1, .pixel_dy = 0, .row_dx = 0, .row_dy = 1,
    };
    return true;
  }
  if (sin_value == ROTATED_RASTER_TRIG_RATIO && cos_value == 0) {
    *cardinal = (RotatedRasterCardinal) {
      .pixel_dx = 0, .pixel_dy = 1, .row_dx = -1, .row_dy = 0,
    };
    return true;
  }
  if (sin_value == 0 && cos_value == -ROTATED_RASTER_TRIG_RATIO) {
    *cardinal = (RotatedRasterCardinal) {
      .pixel_dx = -1, .pixel_dy = 0, .row_dx = 0, .row_dy = -1,
    };
    return true;
  }
  if (sin_value == -ROTATED_RASTER_TRIG_RATIO && cos_value == 0) {
    *cardinal = (RotatedRasterCardinal) {
      .pixel_dx = 0, .pixel_dy = -1, .row_dx = 1, .row_dy = 0,
    };
    return true;
  }
  return false;
}

static inline void rotated_raster_cardinal_top_left(
    const RotatedRasterCardinal *cardinal,
    int center_x, int center_y,
    int32_t *world_dx, int32_t *world_dy) {
  int32_t sx = -center_x;
  int32_t sy = -center_y;
  *world_dx = sx * cardinal->pixel_dx + sy * cardinal->row_dx;
  *world_dy = sx * cardinal->pixel_dy + sy * cardinal->row_dy;
}

#endif
