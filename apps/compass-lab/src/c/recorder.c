#include "recorder.h"

void recorder_clear(CompassRecorder *recorder) {
  // Old slots become inaccessible without spending time clearing 40 KiB.
  recorder->count = 0;
  recorder->marker = 0;
  recorder->segment = 0;
  recorder->recording = false;
}

bool recorder_toggle(CompassRecorder *recorder) {
  if (recorder->count == RECORDER_CAPACITY) return false;
  if (!recorder->recording && recorder->segment < UINT16_MAX) recorder->segment++;
  recorder->recording = !recorder->recording;
  return recorder->recording;
}

bool recorder_append(CompassRecorder *recorder, CompassSample sample) {
  if (!recorder->recording || recorder->count == RECORDER_CAPACITY) return false;
  sample.marker = recorder->marker;
  sample.segment = recorder->segment;
  recorder->samples[recorder->count++] = sample;
  if (recorder->count == RECORDER_CAPACITY) recorder->recording = false;
  return true;
}

void recorder_mark(CompassRecorder *recorder) {
  if (recorder->marker < UINT16_MAX) recorder->marker++;
}

int32_t recorder_clockwise_centi(int32_t native_heading) {
  int32_t angle = native_heading % RECORDER_TURN_UNITS;
  if (angle < 0) angle += RECORDER_TURN_UNITS;
  // This conversion is for the screen only. Export retains the native integer.
  return (int32_t)((int64_t)(RECORDER_TURN_UNITS - angle) * 36000 /
                   RECORDER_TURN_UNITS) % 36000;
}
