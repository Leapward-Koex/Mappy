#include <assert.h>
#include <stdio.h>
#include "bearing-integration-shim.h"
#include "../apps/pebble-watch/src/c/map_geometry.c"

static void reset_integration(void) {
  test_now_ms = 1000000;
  bearing_tracker_reset(&s_bearing_tracker);
  test_dirty = test_coverage = test_queue = 0;
  test_scheduled = false;
  s_menu_mode = MenuNone; s_arrival_dialog_visible = false;
  s_map_orientation = 1; s_manual_pan = false; s_has_gps = true;
  s_gps_received_at = test_now_ms / 1000;
  s_declination_valid = false; s_declination_centi_degrees = 0;
  s_compass_heading_degrees = s_compass_magnetic_degrees = -1;
  s_compass_heading_centi_degrees = s_compass_magnetic_centi_degrees = -1;
  s_heading_degrees = -1;
  s_map_bearing_display_centi_degrees = s_map_bearing_target_centi_degrees = -1;
}

static void publish_tick(uint32_t elapsed_ms) {
  test_now_ms += elapsed_ms;
  (void)advance_map_bearing_smoothing();
}

#ifdef PBL_COMPASS
static void raw_compass(int32_t clockwise_centi, CompassStatus status) {
  int32_t native = (TRIG_MAX_ANGLE - (int32_t)(
      ((int64_t)clockwise_centi * TRIG_MAX_ANGLE + 18000) / 36000)) % TRIG_MAX_ANGLE;
  update_compass_heading((CompassHeadingData){.magnetic_heading = native,
      .compass_status = status});
}

static void test_fresh_input_and_publication(void) {
  reset_integration();
  start_compass_service();
  assert(test_filter_after_subscribe && test_filter == 0);
  raw_compass(1000, CompassStatusCalibrated);
  assert(s_map_bearing_display_centi_degrees == -1 && test_scheduled);
  assert(active_map_bearing_centi_degrees() == 0);
  publish_tick(30);
  int32_t published = s_map_bearing_display_centi_degrees;
  assert(abs(published - 1000) <= 1);
  uint32_t first_sample = s_bearing_tracker.sampled_at_ms;
  for (unsigned i = 0; i < 4; i++) {
    test_now_ms += 20;
    assert(!sync_map_bearing_smoothing(true));
    assert(s_bearing_tracker.sampled_at_ms == first_sample);
    assert(s_map_bearing_display_centi_degrees == published);
  }
  test_now_ms += 90;
  raw_compass(1040, CompassStatusCalibrated);
  assert(s_compass_heading_degrees == 10);
  assert(abs(s_compass_heading_centi_degrees - 1040) <= 1);
  assert(s_bearing_tracker.sampled_at_ms == test_now_ms);
  assert(s_map_bearing_display_centi_degrees == published);
  uint32_t second_sample = s_bearing_tracker.sampled_at_ms;
  test_now_ms += 200;
  raw_compass(1040, CompassStatusCalibrated);
  assert(s_bearing_tracker.sampled_at_ms > second_sample);
  assert(s_map_bearing_display_centi_degrees == published);
  publish_tick(30);
  assert(s_map_bearing_display_centi_degrees != published);
}

static void test_invalid_recovery_and_declination(void) {
  reset_integration();
  raw_compass(4500, CompassStatusCalibrated);
  publish_tick(30);
  int32_t published = s_map_bearing_display_centi_degrees;
  unsigned dirty = test_dirty;
  raw_compass(4500, CompassStatusDataInvalid);
  assert(!compass_heading_is_valid() && !map_orientation_active());
  assert(!map_bearing_smoothing_active() && test_dirty > dirty);
  assert(s_map_bearing_display_centi_degrees == published);
  dirty = test_dirty;
  raw_compass(4500, CompassStatusCalibrated);
  assert(map_orientation_active() && test_dirty > dirty);
  assert(s_map_bearing_display_centi_degrees == published);
  uint32_t sampled = s_bearing_tracker.sampled_at_ms;
  s_declination_valid = true; s_declination_centi_degrees = 25;
  refresh_corrected_compass_heading();
  assert(s_compass_heading_centi_degrees == published + 25);
  sync_map_bearing_smoothing(true);
  assert(s_map_bearing_display_centi_degrees == published);
  assert(!s_bearing_tracker.has_sample || s_bearing_tracker.sampled_at_ms == sampled);
  assert(s_bearing_tracker.sensor_velocity_milli_per_second == 0);
  assert(bearing_tracker_prediction_centi_degrees(&s_bearing_tracker, test_now_ms) == 0);
  raw_compass(4500, CompassStatusCalibrating);
  assert(compass_heading_is_valid());
  assert(!s_bearing_tracker.prediction_allowed);
}

static void test_menu_manual_and_north_reset(void) {
  reset_integration();
  raw_compass(1000, CompassStatusCalibrated); publish_tick(30);
  int32_t published = s_map_bearing_display_centi_degrees;
  s_menu_mode = 1; pause_map_bearing_rendering();
  test_now_ms += 200; raw_compass(9000, CompassStatusCalibrated);
  assert(s_map_bearing_display_centi_degrees == published);
  assert(!map_bearing_smoothing_active() && !s_bearing_tracker.valid);
  s_menu_mode = MenuNone;
  assert(resume_map_bearing_rendering());
  assert(s_map_bearing_display_centi_degrees == 9000);
  assert(!s_bearing_tracker.has_sample && !map_bearing_smoothing_active());
  s_manual_pan = true;
  int32_t cone = -1;
  assert(active_map_bearing_centi_degrees() == 0);
  assert(active_facing_heading_degrees(&cone) && cone == 90);
  s_manual_pan = false;
  reset_map_bearing_display_to_north();
  assert(s_map_bearing_display_centi_degrees == 0);
  assert(bearing_tracker_display_centi_degrees(&s_bearing_tracker) == 0);
  sync_map_bearing_smoothing(true);
  assert(s_map_bearing_display_centi_degrees == 0 && test_scheduled);
  publish_tick(30);
  assert(s_map_bearing_display_centi_degrees > 0);
  int32_t position = s_bearing_tracker.display_milli_degrees;
  int32_t velocity = s_bearing_tracker.velocity_milli_per_second;
  request_map_bearing_acquisition();
  assert(s_bearing_tracker.display_milli_degrees == position);
  assert(s_bearing_tracker.velocity_milli_per_second == velocity);
  s_arrival_dialog_visible = true; pause_map_bearing_rendering();
  assert(!map_bearing_smoothing_active());
  s_arrival_dialog_visible = false; resume_map_bearing_rendering();
  assert(s_map_bearing_display_centi_degrees == 9000);
}
#else
static void test_phone_fresh_adapter(void) {
  reset_integration();
  s_heading_degrees = 90;
  observe_map_bearing_centi_degrees(9000, test_now_ms, false);
  assert(s_map_bearing_display_centi_degrees == -1 && test_scheduled);
  publish_tick(30);
  assert(s_map_bearing_display_centi_degrees == 9000);
  uint32_t sampled = s_bearing_tracker.sampled_at_ms;
  test_now_ms += 100;
  sync_map_bearing_smoothing(true);
  assert(s_bearing_tracker.sampled_at_ms == sampled);
  assert(!s_bearing_tracker.prediction_allowed);
  update_debug_compass_centi_degrees(18000, test_now_ms);
  assert(s_bearing_tracker.sampled_at_ms == sampled);
  assert(s_map_bearing_target_centi_degrees == 9000);
  assert(s_map_bearing_display_centi_degrees == 9000);
  test_now_ms += 31000;
  assert(!phone_heading_is_usable() && !map_bearing_smoothing_active());
}
#endif

int main(void) {
#ifdef PBL_COMPASS
  test_fresh_input_and_publication();
  test_invalid_recovery_and_declination();
  test_menu_manual_and_north_reset();
  puts("Bearing integration: native precision, fresh input, publication, validity, declination, menus, cone, acquisition and north-up reset passed");
#else
  test_phone_fresh_adapter();
  puts("Bearing integration: phone observation, camera sync and freshness passed");
#endif
  return 0;
}
