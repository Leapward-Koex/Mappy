#include "compass_filter.h"

#include <string.h>

static uint32_t elapsed_ms(uint32_t now_ms, uint32_t then_ms) {
  return now_ms - then_ms;
}

static int16_t normalize_heading(int16_t heading_degrees) {
  int16_t normalized = heading_degrees % 360;
  return normalized < 0 ? normalized + 360 : normalized;
}

int16_t compass_filter_shortest_delta(int16_t from_degrees,
                                      int16_t to_degrees) {
  int16_t delta = normalize_heading(to_degrees) -
      normalize_heading(from_degrees);
  if (delta > 180) {
    delta -= 360;
  } else if (delta < -180) {
    delta += 360;
  }
  return delta;
}

uint16_t compass_filter_angular_distance(int16_t first_degrees,
                                         int16_t second_degrees) {
  int16_t delta = compass_filter_shortest_delta(first_degrees, second_degrees);
  return (uint16_t)(delta < 0 ? -delta : delta);
}

static void reset_calibration(CompassFilter *filter) {
  filter->calibration_count = 0;
  filter->calibration_anchor = -1;
  filter->calibration_min_delta = 0;
  filter->calibration_max_delta = 0;
  filter->calibration_started_ms = 0;
}

static CompassFilterResult reject_outlier(CompassFilter *filter) {
  if (!filter->outlier_pending) {
    return CompassFilterResultNone;
  }
  filter->outlier_pending = false;
  filter->outlier_heading = -1;
  filter->outlier_started_ms = 0;
  return CompassFilterResultOutlierRejected;
}

static CompassFilterResult invalidate_heading(CompassFilter *filter) {
  CompassFilterResult result = reject_outlier(filter);
  reset_calibration(filter);
  if (filter->heading_usable) {
    result |= CompassFilterResultHeadingLost;
  }
  filter->heading_usable = false;
  filter->accepted_heading = -1;
  return result;
}

void compass_filter_reset(CompassFilter *filter, uint32_t now_ms) {
  memset(filter, 0, sizeof(*filter));
  filter->status = CompassFilterStatusUnknown;
  filter->accepted_heading = -1;
  filter->calibration_anchor = -1;
  filter->outlier_heading = -1;
  filter->last_service_ms = now_ms;
}

static CompassFilterResult accept_heading(CompassFilter *filter,
                                          int16_t heading_degrees) {
  bool was_usable = filter->heading_usable;
  filter->heading_usable = true;
  filter->accepted_heading = normalize_heading(heading_degrees);
  filter->outlier_pending = false;
  filter->outlier_heading = -1;
  filter->outlier_started_ms = 0;
  CompassFilterResult result = CompassFilterResultHeadingAccepted;
  if (!was_usable) {
    result |= CompassFilterResultHeadingAcquired;
  }
  return result;
}

static CompassFilterResult process_calibration_sample(
    CompassFilter *filter, int16_t heading_degrees, uint32_t now_ms) {
  int16_t heading = normalize_heading(heading_degrees);
  if (filter->calibration_count == 0) {
    filter->calibration_count = 1;
    filter->calibration_anchor = heading;
    filter->calibration_min_delta = 0;
    filter->calibration_max_delta = 0;
    filter->calibration_started_ms = now_ms;
    return CompassFilterResultNone;
  }

  int16_t delta = compass_filter_shortest_delta(
      filter->calibration_anchor, heading);
  int16_t next_min = delta < filter->calibration_min_delta ?
      delta : filter->calibration_min_delta;
  int16_t next_max = delta > filter->calibration_max_delta ?
      delta : filter->calibration_max_delta;
  if (delta < -COMPASS_FILTER_CALIBRATION_SPREAD_DEGREES ||
      delta > COMPASS_FILTER_CALIBRATION_SPREAD_DEGREES ||
      next_max - next_min > COMPASS_FILTER_CALIBRATION_SPREAD_DEGREES) {
    filter->calibration_count = 1;
    filter->calibration_anchor = heading;
    filter->calibration_min_delta = 0;
    filter->calibration_max_delta = 0;
    filter->calibration_started_ms = now_ms;
    return CompassFilterResultNone;
  }

  if (filter->calibration_count < UINT8_MAX) {
    filter->calibration_count++;
  }
  filter->calibration_min_delta = next_min;
  filter->calibration_max_delta = next_max;
  if (filter->calibration_count >= COMPASS_FILTER_CALIBRATION_SAMPLES &&
      elapsed_ms(now_ms, filter->calibration_started_ms) >=
          COMPASS_FILTER_CALIBRATION_SPAN_MS) {
    reset_calibration(filter);
    return accept_heading(filter, heading);
  }
  return CompassFilterResultNone;
}

static CompassFilterResult process_usable_sample(CompassFilter *filter,
                                                 int16_t heading_degrees,
                                                 uint32_t now_ms) {
  int16_t heading = normalize_heading(heading_degrees);
  uint16_t delta = compass_filter_angular_distance(
      filter->accepted_heading, heading);

  if (filter->outlier_pending) {
    uint32_t pending_elapsed = elapsed_ms(now_ms,
                                         filter->outlier_started_ms);
    if (pending_elapsed >= COMPASS_FILTER_OUTLIER_TIMEOUT_MS) {
      return reject_outlier(filter);
    }
    if (compass_filter_angular_distance(filter->outlier_heading, heading) <=
        COMPASS_FILTER_OUTLIER_CONFIRM_DEGREES) {
      filter->outlier_heading = heading;
      if (pending_elapsed >= COMPASS_FILTER_OUTLIER_CONFIRM_MS) {
        return accept_heading(filter, heading);
      }
      return CompassFilterResultOutlierPending;
    }
    if (delta <= COMPASS_FILTER_OUTLIER_CONFIRM_DEGREES) {
      return reject_outlier(filter);
    }
    if (delta <= COMPASS_FILTER_NORMAL_DELTA_DEGREES) {
      CompassFilterResult result = reject_outlier(filter);
      if (delta <= COMPASS_FILTER_DEADBAND_DEGREES) {
        return result;
      }
      return result | accept_heading(filter, heading);
    }
    return CompassFilterResultOutlierPending;
  }

  if (delta <= COMPASS_FILTER_DEADBAND_DEGREES) {
    return CompassFilterResultNone;
  }
  if (delta <= COMPASS_FILTER_NORMAL_DELTA_DEGREES) {
    return accept_heading(filter, heading);
  }

  filter->outlier_pending = true;
  filter->outlier_heading = heading;
  filter->outlier_started_ms = now_ms;
  return CompassFilterResultOutlierPending;
}

CompassFilterResult compass_filter_process(CompassFilter *filter,
                                           CompassFilterStatus status,
                                           int16_t heading_degrees,
                                           uint32_t now_ms) {
  CompassFilterResult result = CompassFilterResultNone;
  if ((status == CompassFilterStatusCalibrating ||
       status == CompassFilterStatusCalibrated) &&
      (heading_degrees < 0 || heading_degrees >= 360)) {
    status = CompassFilterStatusDataInvalid;
  }
  CompassFilterStatus previous_status = filter->status;
  bool status_changed = !filter->status_known || previous_status != status;
  filter->service_seen = true;
  filter->last_service_ms = now_ms;
  filter->stale = false;
  filter->status_known = true;
  filter->status = status;
  if (status_changed) {
    result |= CompassFilterResultStatusChanged;
  }

  if (status == CompassFilterStatusUnavailable) {
    result |= invalidate_heading(filter);
    if (status_changed) {
      result |= CompassFilterResultServiceUnavailable;
    }
    return result;
  }
  if (status == CompassFilterStatusDataInvalid) {
    result |= invalidate_heading(filter);
    return result;
  }
  if (status == CompassFilterStatusCalibrating) {
    if (status_changed) {
      result |= invalidate_heading(filter);
      result |= CompassFilterResultCalibrationStarted;
    }
    if (!filter->heading_usable) {
      return result |
          process_calibration_sample(filter, heading_degrees, now_ms);
    }
    return result | process_usable_sample(filter, heading_degrees, now_ms);
  }
  if (status != CompassFilterStatusCalibrated) {
    filter->status = CompassFilterStatusDataInvalid;
    result |= invalidate_heading(filter);
    return result;
  }

  reset_calibration(filter);
  if (!filter->heading_usable) {
    return result | accept_heading(filter, heading_degrees);
  }
  return result | process_usable_sample(filter, heading_degrees, now_ms);
}

CompassFilterResult compass_filter_tick(CompassFilter *filter,
                                        uint32_t now_ms) {
  CompassFilterResult result = CompassFilterResultNone;
  if (filter->outlier_pending &&
      elapsed_ms(now_ms, filter->outlier_started_ms) >=
          COMPASS_FILTER_OUTLIER_TIMEOUT_MS) {
    result |= reject_outlier(filter);
  }
  if (!filter->stale &&
      elapsed_ms(now_ms, filter->last_service_ms) >
          COMPASS_FILTER_STALE_MS) {
    result |= invalidate_heading(filter);
    filter->stale = true;
    result |= CompassFilterResultStale;
  }
  return result;
}
