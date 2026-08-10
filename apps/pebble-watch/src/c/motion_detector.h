#ifndef MAPPY_MOTION_DETECTOR_H
#define MAPPY_MOTION_DETECTOR_H

#include <stdbool.h>
#include <stdint.h>

typedef enum {
  MotionDetectorIdle,
  MotionDetectorWalking,
  MotionDetectorRaiseCandidate,
  MotionDetectorLooking,
} MotionDetectorState;

typedef enum {
  MotionDetectorEventNone = 0,
  MotionDetectorEventWalking = 1 << 0,
  MotionDetectorEventWatchLook = 1 << 1,
} MotionDetectorEvent;

typedef struct {
  int16_t x;
  int16_t y;
  int16_t z;
  uint32_t timestamp_ms;
  bool did_vibrate;
} MotionSample;

typedef struct {
  MotionDetectorState state;
  bool gravity_initialized;
  int32_t gravity_x;
  int32_t gravity_y;
  int32_t gravity_z;

  uint8_t peak_count;
  uint32_t first_peak_ms;
  uint32_t last_peak_ms;

  bool walk_episode_active;
  uint32_t last_walking_ms;
  bool baseline_valid;
  int32_t baseline_x;
  int32_t baseline_y;
  int32_t baseline_z;

  uint32_t candidate_started_ms;
  uint32_t stable_started_ms;
  int32_t stable_x;
  int32_t stable_y;
  int32_t stable_z;
} MotionDetector;

void motion_detector_reset(MotionDetector *detector);
MotionDetectorEvent motion_detector_process(MotionDetector *detector,
                                            const MotionSample *sample);

#endif
