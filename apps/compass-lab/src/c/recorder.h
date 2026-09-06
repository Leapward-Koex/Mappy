#ifndef COMPASS_LAB_RECORDER_H
#define COMPASS_LAB_RECORDER_H
#include <stdbool.h>
#include <stdint.h>

#define RECORDER_CAPACITY 2048
#define RECORDER_TURN_UNITS 65536

// Exact CompassHeadingData fields plus the application's callback arrival time.
// No filtering, inferred samples, rounding, or interval clamping is recorded.
typedef struct {
  uint32_t seconds;
  int32_t magnetic;
  int32_t true_heading;
  uint16_t milliseconds;
  uint16_t marker;
  int8_t status;
  bool declination_valid;
  uint16_t segment;
} CompassSample;

typedef struct {
  CompassSample samples[RECORDER_CAPACITY];
  uint16_t count;
  uint16_t marker;
  uint16_t segment;
  bool recording;
} CompassRecorder;

void recorder_clear(CompassRecorder *recorder);
bool recorder_toggle(CompassRecorder *recorder);
bool recorder_append(CompassRecorder *recorder, CompassSample sample);
void recorder_mark(CompassRecorder *recorder);
int32_t recorder_clockwise_centi(int32_t native_heading);
#endif
