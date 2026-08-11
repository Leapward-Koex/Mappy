#include "mappy.h"

#define MOTION_SAMPLES_PER_UPDATE 5
#define BEARING_REACQUIRE_DURATION_MS 1500
#define ROUTE_START_REACQUIRE_PENDING_MS 3000
#define LOG_CATEGORY_MOTION 0
#define LOG_MOTION_WALKING 8
#define LOG_MOTION_WATCH_LOOK 9
#define LOG_MOTION_REACQUIRE 10

static MotionDetector s_motion_detector;
static bool s_motion_service_subscribed;

static bool s_bearing_reacquire_running;
static BearingReacquireReason s_bearing_reacquire_reason;
static time_t s_bearing_reacquire_started_s;
static uint16_t s_bearing_reacquire_started_ms;

static bool s_route_start_reacquire_pending;
static time_t s_route_start_reacquire_pending_s;
static uint16_t s_route_start_reacquire_pending_ms;

static int32_t elapsed_since(time_t started_s, uint16_t started_ms) {
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  return (int32_t)(now_s - started_s) * 1000 +
      (int32_t)now_ms - (int32_t)started_ms;
}

static bool face_forward_route_context_active(void) {
  return s_map_orientation == 1 && !s_manual_pan &&
      s_menu_mode == MenuNone && has_active_route();
}

static bool bearing_reacquire_context_active(void) {
  return s_has_gps && face_forward_route_context_active();
}

static bool motion_detection_should_run(void) {
  return bearing_reacquire_context_active() && s_route_point_count > 1 &&
      s_active_route_mode == TRAVEL_MODE_WALK;
}

const char *bearing_reacquire_reason_label(BearingReacquireReason reason) {
  switch (reason) {
    case BearingReacquireRouteStart:
      return "route_start";
    case BearingReacquireWatchLook:
      return "watch_look";
    case BearingReacquireNone:
    default:
      return "none";
  }
}

void cancel_bearing_reacquire(void) {
  s_bearing_reacquire_running = false;
  s_bearing_reacquire_reason = BearingReacquireNone;
  s_route_start_reacquire_pending = false;
}

bool bearing_reacquire_active(void) {
  if (!s_bearing_reacquire_running) {
    return false;
  }
  int32_t elapsed = elapsed_since(s_bearing_reacquire_started_s,
                                  s_bearing_reacquire_started_ms);
  if (elapsed >= 0 && elapsed > BEARING_REACQUIRE_DURATION_MS) {
    s_bearing_reacquire_running = false;
    s_bearing_reacquire_reason = BearingReacquireNone;
    return false;
  }
  return true;
}

void begin_bearing_reacquire(BearingReacquireReason reason) {
  if (reason == BearingReacquireNone ||
      !bearing_reacquire_context_active()) {
    return;
  }
  s_route_start_reacquire_pending = false;
  s_bearing_reacquire_running = true;
  s_bearing_reacquire_reason = reason;
  time_ms(&s_bearing_reacquire_started_s,
          &s_bearing_reacquire_started_ms);
  APP_LOG(APP_LOG_LEVEL_INFO, "Bearing reacquire reason=%s duration=%dms",
          bearing_reacquire_reason_label(reason),
          BEARING_REACQUIRE_DURATION_MS);
  send_log_event(LOG_CATEGORY_MOTION, LOG_MOTION_REACQUIRE, reason,
                 "bearing reacquire");
}

void arm_route_start_bearing_reacquire(void) {
  motion_detector_reset(&s_motion_detector);
  s_route_start_reacquire_pending = false;
  if (!face_forward_route_context_active()) {
    return;
  }
  if (bearing_reacquire_context_active() && map_orientation_active()) {
    begin_bearing_reacquire(BearingReacquireRouteStart);
    return;
  }
  s_route_start_reacquire_pending = true;
  time_ms(&s_route_start_reacquire_pending_s,
          &s_route_start_reacquire_pending_ms);
}

void maybe_begin_pending_route_start_reacquire(void) {
  if (!s_route_start_reacquire_pending) {
    return;
  }
  int32_t elapsed = elapsed_since(s_route_start_reacquire_pending_s,
                                  s_route_start_reacquire_pending_ms);
  if (!face_forward_route_context_active() ||
      (elapsed >= 0 && elapsed > ROUTE_START_REACQUIRE_PENDING_MS)) {
    s_route_start_reacquire_pending = false;
    return;
  }
  if (bearing_reacquire_context_active() && map_orientation_active()) {
    begin_bearing_reacquire(BearingReacquireRouteStart);
  }
}

static void motion_data_handler(AccelData *data, uint32_t num_samples) {
  for (uint32_t i = 0; i < num_samples; i++) {
    MotionSample sample = {
      .x = data[i].x,
      .y = data[i].y,
      .z = data[i].z,
      .timestamp_ms = (uint32_t)data[i].timestamp,
      .did_vibrate = data[i].did_vibrate,
    };
    MotionDetectorEvent event = motion_detector_process(&s_motion_detector,
                                                        &sample);
    if (event & MotionDetectorEventWalking) {
      APP_LOG(APP_LOG_LEVEL_INFO, "Motion state=walking");
      send_log_event(LOG_CATEGORY_MOTION, LOG_MOTION_WALKING, 0,
                     "walking detected");
    }
    if (event & MotionDetectorEventWatchLook) {
      APP_LOG(APP_LOG_LEVEL_INFO, "Motion state=looking");
      send_log_event(LOG_CATEGORY_MOTION, LOG_MOTION_WATCH_LOOK, 0,
                     "watch look detected");
      begin_bearing_reacquire(BearingReacquireWatchLook);
    }
  }
}

void refresh_motion_detection_service(void) {
  if (!face_forward_route_context_active()) {
    cancel_bearing_reacquire();
  } else if (!s_has_gps) {
    s_bearing_reacquire_running = false;
    s_bearing_reacquire_reason = BearingReacquireNone;
  }

  bool should_subscribe = motion_detection_should_run();
  if (should_subscribe && !s_motion_service_subscribed) {
    motion_detector_reset(&s_motion_detector);
    accel_data_service_subscribe(MOTION_SAMPLES_PER_UPDATE,
                                 motion_data_handler);
    if (accel_service_set_sampling_rate(ACCEL_SAMPLING_25HZ) != 0) {
      accel_data_service_unsubscribe();
      send_log_event(LOG_CATEGORY_MOTION, -1, 0, "motion unavailable");
      return;
    }
    s_motion_service_subscribed = true;
    APP_LOG(APP_LOG_LEVEL_INFO, "Motion detection subscribed 25Hz batch=%d",
            MOTION_SAMPLES_PER_UPDATE);
  } else if (!should_subscribe && s_motion_service_subscribed) {
    accel_data_service_unsubscribe();
    s_motion_service_subscribed = false;
    motion_detector_reset(&s_motion_detector);
    APP_LOG(APP_LOG_LEVEL_INFO, "Motion detection unsubscribed");
  }
}

void stop_motion_detection_service(void) {
  if (s_motion_service_subscribed) {
    accel_data_service_unsubscribe();
    s_motion_service_subscribed = false;
  }
  motion_detector_reset(&s_motion_detector);
  cancel_bearing_reacquire();
}
