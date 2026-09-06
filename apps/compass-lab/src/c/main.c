#include <pebble.h>
#include "recorder.h"
#ifdef COMPASS_LAB_TEST_INPUT
#define COMPASS_LAB_IS_TEST 1
#define COMPASS_LAB_TITLE "COMPASS LAB - TEST"
#else
#define COMPASS_LAB_IS_TEST 0
#define COMPASS_LAB_TITLE "COMPASS LAB"
#endif

static Window *s_window;
static Layer *s_layer;
static AppTimer *s_ui_timer, *s_export_timer;
static CompassRecorder s_recorder;
static CompassSample s_latest;
static bool s_seen, s_dirty = true, s_exporting;
static int32_t s_interval_ms;
static uint16_t s_export_index, s_export_number;
static const char *s_notice;

static const char *quality_label(int status) {
  switch (status) {
    case CompassStatusCalibrated: return "Calibrated";
    case CompassStatusCalibrating: return "Calibrating";
    case CompassStatusDataInvalid: return "Calibrate: move wrist";
    default: return "Compass unavailable";
  }
}

static void draw_text(GContext *ctx, const char *text, const char *font,
                      int y, int height, int width) {
  graphics_draw_text(ctx, text, fonts_get_system_font(font),
      GRect(2, y, width - 4, height), GTextOverflowModeTrailingEllipsis,
      GTextAlignmentCenter, NULL);
}

static void draw(Layer *layer, GContext *ctx) {
  int width = layer_get_bounds(layer).size.w;
  char text[64];
  graphics_context_set_text_color(ctx, GColorBlack);
  draw_text(ctx, COMPASS_LAB_TITLE, FONT_KEY_GOTHIC_18_BOLD, 0, 23, width);
  if (s_seen && s_latest.status > CompassStatusDataInvalid) {
    int32_t centi = recorder_clockwise_centi(s_latest.magnetic);
    // Truncate the screen to tenths; recorded headings keep every native bit.
    snprintf(text, sizeof(text), "%ld.%ld°", (long)(centi / 100),
             (long)((centi / 10) % 10));
  } else {
    snprintf(text, sizeof(text), "---.-°");
  }
  draw_text(ctx, text, FONT_KEY_BITHAM_42_BOLD, 23, 54, width);
  draw_text(ctx, s_seen ? quality_label(s_latest.status) : "Waiting for compass",
            FONT_KEY_GOTHIC_18, 77, 23, width);
  if (!s_seen) snprintf(text, sizeof(text), "No callbacks yet");
  else if (s_interval_ms < 0) snprintf(text, sizeof(text), "Clock moved backward");
  else snprintf(text, sizeof(text), "Last interval %ld ms  |  M%u",
                (long)s_interval_ms, (unsigned)s_recorder.marker);
  draw_text(ctx, text, FONT_KEY_GOTHIC_14, 100, 20, width);

  graphics_context_set_fill_color(ctx, s_recorder.recording ? GColorDarkCandyAppleRed :
                           s_exporting ? GColorCobaltBlue : GColorBlack);
  graphics_fill_rect(ctx, GRect(5, 123, width - 10, 27), 3, GCornersAll);
  graphics_context_set_text_color(ctx, GColorWhite);
  if (s_exporting) snprintf(text, sizeof(text), "EXPORT %u / %u",
      (unsigned)s_export_index, (unsigned)s_recorder.count);
  else snprintf(text, sizeof(text), "%s  %u / %u",
      s_recorder.recording ? "REC" :
      s_recorder.count == RECORDER_CAPACITY ? "FULL" :
      s_recorder.count ? "PAUSED" : "READY",
      (unsigned)s_recorder.count, RECORDER_CAPACITY);
  draw_text(ctx, text, FONT_KEY_GOTHIC_18_BOLD, 123, 27, width);
  graphics_context_set_text_color(ctx, GColorBlack);
  draw_text(ctx, "SELECT: record / pause\nUP: mark  |  hold: clear\nDOWN: export  |  hold BACK: exit",
            FONT_KEY_GOTHIC_14, 154, 54, width);
  draw_text(ctx, s_notice ? s_notice : "RAM only: export before exit",
            FONT_KEY_GOTHIC_14, 209, 18, width);
}

static void ui_tick(void *context) {
  (void)context;
  s_ui_timer = NULL;
  if (s_dirty && s_layer) {
    layer_mark_dirty(s_layer);
    s_dirty = false;
  }
  // Compass callbacks never draw, allocate, write flash, or log. The small UI
  // runs at most 10Hz and does not determine the capture cadence.
  s_ui_timer = app_timer_register(100, ui_tick, NULL);
}

static void heading_received(CompassHeadingData heading) {
  time_t seconds;
  uint16_t milliseconds;
  time_ms(&seconds, &milliseconds);
  CompassSample sample = {
    .seconds = (uint32_t)seconds, .milliseconds = milliseconds,
    .magnetic = heading.magnetic_heading, .true_heading = heading.true_heading,
    .status = (int8_t)heading.compass_status,
    .declination_valid = heading.is_declination_valid,
  };
  if (s_seen) {
    int64_t interval = ((int64_t)sample.seconds - s_latest.seconds) * 1000 +
        (int32_t)sample.milliseconds - s_latest.milliseconds;
    s_interval_ms = interval < INT32_MIN ? INT32_MIN :
                    interval > INT32_MAX ? INT32_MAX : (int32_t)interval;
  }
  s_latest = sample;
  s_seen = true;
  bool was_recording = s_recorder.recording;
  recorder_append(&s_recorder, sample);
  if (was_recording && !s_recorder.recording) s_notice = "Full: export; hold UP to clear";
  s_dirty = true;
}

static void export_tick(void *context);

static void schedule_export(void) {
  // Conservative rate for developer-log transport; missing rows are detected
  // by the desktop exporter, and the unchanged buffer can be exported again.
  s_export_timer = app_timer_register(50, export_tick, NULL);
  if (!s_export_timer) {
    s_exporting = false;
    s_notice = "Export interrupted: retry DOWN";
    s_dirty = true;
    APP_LOG(APP_LOG_LEVEL_INFO, "CLAB X e=%u", (unsigned)s_export_number);
  }
}

static void export_tick(void *context) {
  (void)context;
  s_export_timer = NULL;
  const CompassSample *sample = &s_recorder.samples[s_export_index];
  APP_LOG(APP_LOG_LEVEL_INFO,
      "CLAB S e=%u i=%u s=%lu m=%u h=%ld t=%ld c=%d d=%u k=%u r=%u",
      (unsigned)s_export_number, (unsigned)s_export_index,
      (unsigned long)sample->seconds, (unsigned)sample->milliseconds,
      (long)sample->magnetic, (long)sample->true_heading, (int)sample->status,
      (unsigned)sample->declination_valid, (unsigned)sample->marker,
      (unsigned)sample->segment);
  s_export_index++;
  s_dirty = true;
  if (s_export_index < s_recorder.count) {
    schedule_export();
  } else {
    APP_LOG(APP_LOG_LEVEL_INFO, "CLAB E e=%u n=%u",
        (unsigned)s_export_number, (unsigned)s_recorder.count);
    s_exporting = false;
    s_notice = "Export sent; DOWN sends again";
  }
}

static void select_click(ClickRecognizerRef recognizer, void *context) {
  (void)recognizer; (void)context;
  if (s_exporting) return;
  recorder_toggle(&s_recorder);
  s_notice = NULL;
  s_dirty = true;
}

static void mark_click(ClickRecognizerRef recognizer, void *context) {
  (void)recognizer; (void)context;
  if (s_exporting) return;
  recorder_mark(&s_recorder);
  s_dirty = true;
}

static void clear_long_click(ClickRecognizerRef recognizer, void *context) {
  (void)recognizer; (void)context;
  if (s_exporting || s_recorder.recording) {
    s_notice = "Pause before clearing";
  } else {
    recorder_clear(&s_recorder);
    s_notice = "Cleared; SELECT starts capture";
  }
  s_dirty = true;
}

static void export_click(ClickRecognizerRef recognizer, void *context) {
  (void)recognizer; (void)context;
  if (s_exporting) return;
  if (!s_recorder.count) {
    s_notice = "No samples: SELECT to record";
    s_dirty = true;
    return;
  }
  s_recorder.recording = false;
  s_exporting = true;
  s_export_index = 0;
  s_export_number++;
  s_notice = "PC logger must be listening";
  s_dirty = true;
  APP_LOG(APP_LOG_LEVEL_INFO, "CLAB B v=1 e=%u n=%u turn=%lu test=%u",
      (unsigned)s_export_number, (unsigned)s_recorder.count,
      (unsigned long)TRIG_MAX_ANGLE, COMPASS_LAB_IS_TEST);
  schedule_export();
}

static void back_click(ClickRecognizerRef recognizer, void *context) {
  (void)recognizer; (void)context;
  s_recorder.recording = false;
  s_notice = "Export first; hold BACK to exit";
  s_dirty = true;
}

static void exit_long_click(ClickRecognizerRef recognizer, void *context) {
  (void)recognizer; (void)context;
  window_stack_pop_all(true);
}

static void clicks(void *context) {
  (void)context;
  window_single_click_subscribe(BUTTON_ID_SELECT, select_click);
  window_single_click_subscribe(BUTTON_ID_UP, mark_click);
  window_long_click_subscribe(BUTTON_ID_UP, 1200, clear_long_click, NULL);
  window_single_click_subscribe(BUTTON_ID_DOWN, export_click);
  window_single_click_subscribe(BUTTON_ID_BACK, back_click);
  window_long_click_subscribe(BUTTON_ID_BACK, 1200, exit_long_click, NULL);
}

#ifdef COMPASS_LAB_TEST_INPUT
// Emulator-only injection: unavailable in the production PBW. This exercises
// the exact recorder callback, controls, rendering and log exporter without
// pretending QEMU's unavailable compass is physical sensor data.
static void test_inbox(DictionaryIterator *iterator, void *context) {
  (void)context;
  Tuple *magnetic = dict_find(iterator, 0);
  Tuple *status = dict_find(iterator, 2);
  if (!magnetic) return;
  heading_received((CompassHeadingData){
      .magnetic_heading = magnetic->value->int32,
      .true_heading = magnetic->value->int32,
      .compass_status = status ? (CompassStatus)status->value->int32 : CompassStatusCalibrated,
      .is_declination_valid = false,
  });
}
#endif
static void init(void) {
  recorder_clear(&s_recorder);
  s_window = window_create();
  window_set_background_color(s_window, GColorWhite);
  window_set_click_config_provider(s_window, clicks);
  Layer *root = window_get_root_layer(s_window);
  s_layer = layer_create(layer_get_bounds(root));
  layer_set_update_proc(s_layer, draw);
  layer_add_child(root, s_layer);
  window_stack_push(s_window, true);
#ifdef COMPASS_LAB_TEST_INPUT
  app_message_register_inbox_received(test_inbox);
  int result = (int)app_message_open(128, 128);
#else
  compass_service_subscribe(heading_received);
  int result = compass_service_set_heading_filter(0);
#endif
  if (result) s_notice = "Compass filter failed";
  s_ui_timer = app_timer_register(100, ui_tick, NULL);
  APP_LOG(APP_LOG_LEVEL_INFO, "Compass Lab ready: filter=%d capacity=%d heap=%u",
          result, RECORDER_CAPACITY, (unsigned)heap_bytes_free());
}

static void deinit(void) {
  compass_service_unsubscribe();
  if (s_ui_timer) app_timer_cancel(s_ui_timer);
  if (s_export_timer) app_timer_cancel(s_export_timer);
  layer_destroy(s_layer);
  window_destroy(s_window);
}

int main(void) {
  init();
  app_event_loop();
  deinit();
}
