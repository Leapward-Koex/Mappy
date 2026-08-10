#include "motion_detector.h"

#include <string.h>

#define MOTION_GRAVITY_FILTER_DIVISOR 8
#define MOTION_BASELINE_FILTER_DIVISOR 16
#define MOTION_PEAK_THRESHOLD_MG 180
#define MOTION_PEAK_MIN_GAP_MS 250
#define MOTION_PEAK_MAX_GAP_MS 900
#define MOTION_WALK_WINDOW_MS 2000
#define MOTION_WALK_IDLE_MS 1200
#define MOTION_LOOK_AFTER_WALK_MS 2000
#define MOTION_CANDIDATE_TIMEOUT_MS 1500
#define MOTION_LOOK_STABLE_MS 300

// cos(angle)^2 in thousandths. Squared comparisons avoid floating point and
// square roots while keeping the classifier independent of watch orientation.
#define MOTION_COS_SQ_35_PERMILLE 671
#define MOTION_COS_SQ_30_PERMILLE 750
#define MOTION_COS_SQ_12_PERMILLE 957

static int32_t abs_i32(int32_t value) {
  return value < 0 ? -value : value;
}

static uint32_t elapsed_ms(uint32_t now, uint32_t then) {
  return now - then;
}

static int64_t vector_dot(int32_t ax, int32_t ay, int32_t az,
                          int32_t bx, int32_t by, int32_t bz) {
  return (int64_t)ax * bx + (int64_t)ay * by + (int64_t)az * bz;
}

static int64_t vector_norm_sq(int32_t x, int32_t y, int32_t z) {
  return (int64_t)x * x + (int64_t)y * y + (int64_t)z * z;
}

static bool angle_at_least(int32_t ax, int32_t ay, int32_t az,
                           int32_t bx, int32_t by, int32_t bz,
                           int32_t cosine_sq_permille) {
  int64_t dot = vector_dot(ax, ay, az, bx, by, bz);
  int64_t norms = vector_norm_sq(ax, ay, az) * vector_norm_sq(bx, by, bz);
  if (norms <= 0) {
    return false;
  }
  if (dot <= 0) {
    return true;
  }
  return dot * dot * 1000 <= norms * cosine_sq_permille;
}

static bool angle_at_most(int32_t ax, int32_t ay, int32_t az,
                          int32_t bx, int32_t by, int32_t bz,
                          int32_t cosine_sq_permille) {
  int64_t dot = vector_dot(ax, ay, az, bx, by, bz);
  int64_t norms = vector_norm_sq(ax, ay, az) * vector_norm_sq(bx, by, bz);
  if (dot <= 0 || norms <= 0) {
    return false;
  }
  return dot * dot * 1000 >= norms * cosine_sq_permille;
}

static void set_walk_baseline(MotionDetector *detector) {
  detector->baseline_valid = true;
  detector->baseline_x = detector->gravity_x;
  detector->baseline_y = detector->gravity_y;
  detector->baseline_z = detector->gravity_z;
}

static MotionDetectorEvent register_motion_peak(MotionDetector *detector,
                                                uint32_t now) {
  if (detector->peak_count > 0 &&
      elapsed_ms(now, detector->last_peak_ms) < MOTION_PEAK_MIN_GAP_MS) {
    return MotionDetectorEventNone;
  }

  if (detector->peak_count == 0 ||
      elapsed_ms(now, detector->last_peak_ms) > MOTION_PEAK_MAX_GAP_MS ||
      elapsed_ms(now, detector->first_peak_ms) > MOTION_WALK_WINDOW_MS) {
    detector->peak_count = 1;
    detector->first_peak_ms = now;
  } else if (detector->peak_count < UINT8_MAX) {
    detector->peak_count++;
  }
  detector->last_peak_ms = now;

  if (detector->peak_count < 3) {
    return MotionDetectorEventNone;
  }

  detector->last_walking_ms = now;
  if (detector->walk_episode_active ||
      detector->state == MotionDetectorRaiseCandidate) {
    return MotionDetectorEventNone;
  }

  detector->walk_episode_active = true;
  detector->state = MotionDetectorWalking;
  set_walk_baseline(detector);
  return MotionDetectorEventWalking;
}

static bool recently_walking(const MotionDetector *detector, uint32_t now) {
  return detector->walk_episode_active &&
      elapsed_ms(now, detector->last_walking_ms) <= MOTION_LOOK_AFTER_WALK_MS;
}

static void begin_raise_candidate(MotionDetector *detector,
                                  const MotionSample *sample,
                                  uint32_t now) {
  detector->state = MotionDetectorRaiseCandidate;
  detector->candidate_started_ms = now;
  detector->stable_started_ms = now;
  detector->stable_x = sample->x;
  detector->stable_y = sample->y;
  detector->stable_z = sample->z;
}

static MotionDetectorEvent advance_raise_candidate(MotionDetector *detector,
                                                   const MotionSample *sample,
                                                   uint32_t now) {
  if (elapsed_ms(now, detector->candidate_started_ms) >
      MOTION_CANDIDATE_TIMEOUT_MS) {
    detector->state = MotionDetectorIdle;
    detector->walk_episode_active = false;
    detector->baseline_valid = false;
    detector->peak_count = 0;
    return MotionDetectorEventNone;
  }

  bool remains_raised = angle_at_least(
      detector->gravity_x, detector->gravity_y, detector->gravity_z,
      detector->baseline_x, detector->baseline_y, detector->baseline_z,
      MOTION_COS_SQ_30_PERMILLE);
  bool remains_stable = angle_at_most(
      sample->x, sample->y, sample->z,
      detector->stable_x, detector->stable_y, detector->stable_z,
      MOTION_COS_SQ_12_PERMILLE);

  if (!remains_raised || !remains_stable) {
    detector->stable_started_ms = now;
    detector->stable_x = sample->x;
    detector->stable_y = sample->y;
    detector->stable_z = sample->z;
    return MotionDetectorEventNone;
  }

  if (elapsed_ms(now, detector->stable_started_ms) < MOTION_LOOK_STABLE_MS) {
    return MotionDetectorEventNone;
  }

  detector->state = MotionDetectorLooking;
  detector->walk_episode_active = false;
  detector->peak_count = 0;
  return MotionDetectorEventWatchLook;
}

void motion_detector_reset(MotionDetector *detector) {
  memset(detector, 0, sizeof(*detector));
  detector->state = MotionDetectorIdle;
}

MotionDetectorEvent motion_detector_process(MotionDetector *detector,
                                            const MotionSample *sample) {
  if (!detector || !sample || sample->did_vibrate) {
    return MotionDetectorEventNone;
  }

  uint32_t now = sample->timestamp_ms;
  if (!detector->gravity_initialized) {
    detector->gravity_initialized = true;
    detector->gravity_x = sample->x;
    detector->gravity_y = sample->y;
    detector->gravity_z = sample->z;
    return MotionDetectorEventNone;
  }

  detector->gravity_x +=
      (sample->x - detector->gravity_x) / MOTION_GRAVITY_FILTER_DIVISOR;
  detector->gravity_y +=
      (sample->y - detector->gravity_y) / MOTION_GRAVITY_FILTER_DIVISOR;
  detector->gravity_z +=
      (sample->z - detector->gravity_z) / MOTION_GRAVITY_FILTER_DIVISOR;

  int32_t dynamic_mg = abs_i32(sample->x - detector->gravity_x) +
      abs_i32(sample->y - detector->gravity_y) +
      abs_i32(sample->z - detector->gravity_z);
  MotionDetectorEvent event = MotionDetectorEventNone;
  bool step_like_peak = dynamic_mg >= MOTION_PEAK_THRESHOLD_MG &&
      angle_at_most(sample->x, sample->y, sample->z,
                    detector->gravity_x, detector->gravity_y,
                    detector->gravity_z, MOTION_COS_SQ_35_PERMILLE);
  if (step_like_peak) {
    event = register_motion_peak(detector, now);
  }

  if (detector->state == MotionDetectorRaiseCandidate) {
    return (MotionDetectorEvent)(event |
        advance_raise_candidate(detector, sample, now));
  }

  if (detector->state != MotionDetectorLooking && detector->baseline_valid &&
      recently_walking(detector, now) && angle_at_least(
          detector->gravity_x, detector->gravity_y, detector->gravity_z,
          detector->baseline_x, detector->baseline_y, detector->baseline_z,
          MOTION_COS_SQ_35_PERMILLE)) {
    begin_raise_candidate(detector, sample, now);
    return event;
  }

  if (detector->state == MotionDetectorWalking) {
    if (elapsed_ms(now, detector->last_walking_ms) > MOTION_WALK_IDLE_MS) {
      detector->state = MotionDetectorIdle;
    } else {
      detector->baseline_x +=
          (detector->gravity_x - detector->baseline_x) /
          MOTION_BASELINE_FILTER_DIVISOR;
      detector->baseline_y +=
          (detector->gravity_y - detector->baseline_y) /
          MOTION_BASELINE_FILTER_DIVISOR;
      detector->baseline_z +=
          (detector->gravity_z - detector->baseline_z) /
          MOTION_BASELINE_FILTER_DIVISOR;
    }
  }

  if (detector->walk_episode_active &&
      elapsed_ms(now, detector->last_walking_ms) > MOTION_LOOK_AFTER_WALK_MS) {
    detector->walk_episode_active = false;
    detector->baseline_valid = false;
    if (detector->state != MotionDetectorLooking) {
      detector->state = MotionDetectorIdle;
    }
  }
  return event;
}
