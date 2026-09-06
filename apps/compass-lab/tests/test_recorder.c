#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include "../src/c/recorder.h"

int main(void) {
  CompassRecorder recorder = {0};
  CompassSample sample = {.seconds=1788600000, .milliseconds=123,
      .magnetic=65535, .true_heading=-123, .status=0, .declination_valid=false};
  assert(sizeof(CompassSample) == 20);
  assert(!recorder_append(&recorder, sample));
  assert(recorder_toggle(&recorder));
  assert(recorder_append(&recorder, sample));
  assert(recorder_append(&recorder, sample));
  assert(recorder.count == 2); // Repeated and invalid readings are retained.
  assert(recorder.samples[0].magnetic == 65535 && recorder.samples[0].true_heading == -123);
  assert(recorder.samples[0].milliseconds == 123 && recorder.samples[0].status == 0);
  assert(recorder.samples[0].segment == 1);
  recorder_mark(&recorder);
  sample.magnetic = 1; sample.status = 2; sample.declination_valid = true;
  assert(recorder_append(&recorder, sample));
  assert(recorder.samples[2].marker == 1 && recorder.samples[2].magnetic == 1);
  assert(!recorder_toggle(&recorder));
  assert(!recorder_append(&recorder, sample));
  assert(recorder_toggle(&recorder));
  assert(recorder_append(&recorder, sample));
  assert(recorder.samples[3].segment == 2 && recorder.samples[3].marker == 1);
  while (recorder.count < RECORDER_CAPACITY) assert(recorder_append(&recorder, sample));
  assert(!recorder.recording && !recorder_toggle(&recorder));
  assert(!recorder_append(&recorder, sample));
  assert(recorder.samples[0].magnetic == 65535); // Never overwrite oldest data.
  recorder_clear(&recorder);
  assert(recorder.count == 0 && recorder.marker == 0 && recorder.segment == 0);
  assert(recorder_clockwise_centi(0) == 0);
  assert(recorder_clockwise_centi(65536) == 0);
  assert(recorder_clockwise_centi(16384) == 27000);
  assert(recorder_clockwise_centi(-16384) == 9000);
  assert(recorder_clockwise_centi(65535) == 0); // Screen only, raw bit retained above.
  assert(recorder_clockwise_centi(INT32_MIN) >= 0);
  puts("Recorder: exact raw samples, duplicates, invalid data, segments, markers, capacity and wrap passed");
}
