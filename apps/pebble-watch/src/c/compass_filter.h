#ifndef MAPPY_COMPASS_FILTER_H
#define MAPPY_COMPASS_FILTER_H

#include <stdbool.h>
#include <stdint.h>

#define COMPASS_FILTER_DEADBAND_DEGREES 3
#define COMPASS_FILTER_NORMAL_DELTA_DEGREES 60
#define COMPASS_FILTER_OUTLIER_CONFIRM_DEGREES 15
#define COMPASS_FILTER_OUTLIER_CONFIRM_MS 200
#define COMPASS_FILTER_OUTLIER_TIMEOUT_MS 750
#define COMPASS_FILTER_CALIBRATION_SAMPLES 3
#define COMPASS_FILTER_CALIBRATION_SPAN_MS 250
#define COMPASS_FILTER_CALIBRATION_SPREAD_DEGREES 20
#define COMPASS_FILTER_STALE_MS 5000

typedef enum {
  CompassFilterStatusUnavailable = -1,
  CompassFilterStatusDataInvalid = 0,
  CompassFilterStatusCalibrating = 1,
  CompassFilterStatusCalibrated = 2,
  CompassFilterStatusUnknown = 3,
} CompassFilterStatus;

typedef enum {
  CompassFilterResultNone = 0,
  CompassFilterResultStatusChanged = 1 << 0,
  CompassFilterResultHeadingAccepted = 1 << 1,
  CompassFilterResultHeadingAcquired = 1 << 2,
  CompassFilterResultHeadingLost = 1 << 3,
  CompassFilterResultCalibrationStarted = 1 << 4,
  CompassFilterResultServiceUnavailable = 1 << 5,
  CompassFilterResultOutlierPending = 1 << 6,
  CompassFilterResultOutlierRejected = 1 << 7,
  CompassFilterResultStale = 1 << 8,
} CompassFilterResult;

typedef struct {
  CompassFilterStatus status;
  bool status_known;
  bool heading_usable;
  bool stale;
  bool service_seen;
  int16_t accepted_heading;
  uint32_t last_service_ms;

  uint8_t calibration_count;
  int16_t calibration_anchor;
  int16_t calibration_min_delta;
  int16_t calibration_max_delta;
  uint32_t calibration_started_ms;

  bool outlier_pending;
  int16_t outlier_heading;
  uint32_t outlier_started_ms;
} CompassFilter;

void compass_filter_reset(CompassFilter *filter, uint32_t now_ms);
int16_t compass_filter_shortest_delta(int16_t from_degrees,
                                      int16_t to_degrees);
uint16_t compass_filter_angular_distance(int16_t first_degrees,
                                         int16_t second_degrees);
CompassFilterResult compass_filter_process(CompassFilter *filter,
                                           CompassFilterStatus status,
                                           int16_t heading_degrees,
                                           uint32_t now_ms);
CompassFilterResult compass_filter_tick(CompassFilter *filter,
                                        uint32_t now_ms);

#endif
