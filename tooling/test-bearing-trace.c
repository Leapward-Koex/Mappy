// Host-only trace checks. Compile with and without -DMAPPY_BEARING_TRACE.
#include <assert.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../apps/pebble-watch/src/c/bearing_trace.h"

#ifndef MAPPY_BEARING_TRACE
int main(void) {
  unsigned evaluated = 0;
  bearing_trace_init();
  bearing_trace_sample(evaluated++, evaluated++, evaluated++);
  bearing_trace_frame(evaluated++, evaluated++, evaluated++, evaluated++, evaluated++);
  bearing_trace_set_active(evaluated++);
  bearing_trace_shutdown();
  assert(evaluated == 0);
  puts("Bearing trace disabled: hooks do not evaluate arguments");
  return 0;
}
#else
#define MAPPY_BEARING_TRACE_HOST_TEST
#define APP_LOG_LEVEL_INFO 1
typedef struct { bool armed; void (*callback)(void *); } AppTimer;
static AppTimer timer;
static bool fail_registration, fail_allocation, in_hot_hook, shared_animation_active;
static unsigned allocation_attempts, live_allocations, frees;
static unsigned registrations, cancellations, log_count;
static char logs[256][128];

static AppTimer *app_timer_register(uint32_t delay,
                                    void (*callback)(void *), void *context) {
  assert(delay == 20 && context == NULL && !timer.armed);
  registrations++;
  if (fail_registration) return NULL;
  timer.armed = true;
  timer.callback = callback;
  return &timer;
}
static void app_timer_cancel(AppTimer *value) {
  assert(value == &timer && timer.armed);
  timer.armed = false;
  cancellations++;
}
static void trace_test_log(int level, const char *format, ...) {
  assert(level == APP_LOG_LEVEL_INFO && !in_hot_hook);
  assert(log_count < sizeof(logs) / sizeof(logs[0]));
  va_list args;
  va_start(args, format);
  int length = vsnprintf(logs[log_count], sizeof(logs[0]), format, args);
  va_end(args);
  assert(length > 0 && length < (int)sizeof(logs[0]));
  log_count++;
}
#define APP_LOG(...) trace_test_log(__VA_ARGS__)
static bool visual_animations_active(void) { return shared_animation_active; }
static void *trace_test_malloc(size_t bytes) {
  assert(!in_hot_hook && bytes == 64 * 16);
  allocation_attempts++;
  if (fail_allocation) return NULL;
  void *result = malloc(bytes);
  assert(result != NULL);
  live_allocations++;
  return result;
}
static void trace_test_free(void *value) {
  assert(!in_hot_hook);
  if (value) {
    assert(live_allocations == 1);
    live_allocations--;
    frees++;
  }
  free(value);
}
#define malloc trace_test_malloc
#define free trace_test_free
#include "../apps/pebble-watch/src/c/bearing_trace.c"
#undef malloc
#undef free

static unsigned count_prefix(const char *prefix) {
  unsigned count = 0;
  for (unsigned i = 0; i < log_count; i++) {
    if (strncmp(logs[i], prefix, strlen(prefix)) == 0) count++;
  }
  return count;
}
static void reset(void) {
  bearing_trace_shutdown();
  assert(!timer.armed && live_allocations == 0);
  allocation_attempts = frees = 0;
  log_count = registrations = cancellations = 0;
  fail_registration = fail_allocation = in_hot_hook = shared_animation_active = false;
  bearing_trace_init();
}
static void fire(void) {
  assert(timer.armed);
  unsigned before = count_prefix("MAPPY_BTRACE t=");
  timer.armed = false;
  timer.callback(NULL);
  unsigned after = count_prefix("MAPPY_BTRACE t=");
  assert(after - before <= 4);
}
static void drain(void) {
  unsigned callbacks = 0;
  while (timer.armed) {
    assert(++callbacks <= 16);
    fire();
  }
}
static void active(bool value) {
  in_hot_hook = true;
  bearing_trace_set_active(value);
  in_hot_hook = false;
}
static void sample(uint32_t at, int32_t raw, uint8_t flags) {
  in_hot_hook = true;
  bearing_trace_sample(at, raw, flags);
  in_hot_hook = false;
}
static void frame(uint32_t at, int32_t target, int32_t display, int32_t velocity,
                   uint8_t flags) {
  in_hot_hook = true;
  bearing_trace_frame(at, target, display, velocity, flags);
  in_hot_hook = false;
}
static void assert_record(unsigned index, uint32_t timestamp, unsigned raw,
                          unsigned target, unsigned display, int velocity,
                          unsigned age, unsigned interval, unsigned flags) {
  unsigned seen = 0;
  for (unsigned i = 0; i < log_count; i++) {
    if (strncmp(logs[i], "MAPPY_BTRACE t=", 15) != 0) continue;
    if (seen++ != index) continue;
    unsigned long actual_at;
    unsigned actual_raw, actual_target, actual_display, actual_age;
    unsigned actual_interval, actual_flags;
    int actual_velocity;
    assert(sscanf(logs[i],
        "MAPPY_BTRACE t=%lu r=%u g=%u p=%u v=%d a=%u dt=%u f=%u",
        &actual_at, &actual_raw, &actual_target, &actual_display, &actual_velocity,
        &actual_age, &actual_interval, &actual_flags) == 8);
    assert(actual_at == timestamp && actual_raw == raw && actual_target == target);
    assert(actual_display == display && actual_velocity == velocity);
    assert(actual_age == age && actual_interval == interval && actual_flags == flags);
    return;
  }
  assert(!"missing trace record");
}

static void test_allocation_lifecycle(void) {
  reset();
  void *records = s_trace.records;
  bearing_trace_init();
  assert(s_trace.records == records && allocation_attempts == 1);
  bearing_trace_shutdown();
  bearing_trace_shutdown();
  assert(live_allocations == 0 && frees == 1);
  fail_allocation = true;
  bearing_trace_init();
  assert(allocation_attempts == 2 && live_allocations == 0);
  assert(count_prefix("MAPPY_BTRACE allocation failed") == 1);
  unsigned prior_logs = log_count;
  active(true);
  sample(0, 0, BearingTraceRawValid);
  frame(30, 100, 50, 100, 0);
  active(false);
  bearing_trace_init();
  assert(allocation_attempts == 2 && !timer.armed && log_count == prior_logs);
  bearing_trace_shutdown();
  fail_allocation = false;
  bearing_trace_init();
  assert(allocation_attempts == 3 && live_allocations == 1);
}

static void test_ring_and_idle_flush(void) {
  reset();
  active(true);
  sample(0, 100, BearingTraceRawValid | BearingTraceCalibrated);
  for (unsigned i = 0; i < 80; i++) {
    frame(i * 30, 101, i, 3000, BearingTraceMoving | BearingTraceFaceForward);
  }
  assert(log_count == 0 && registrations == 0);
  active(false);
  assert(log_count == 0 && timer.armed);
  drain();
  assert(count_prefix("MAPPY_BTRACE t=") == 64);
  assert(strstr(logs[0], "begin n=64 drop=16") != NULL);
  assert_record(0, 480, 100, 101, 16, 300, 480, 30, 51);
  assert_record(63, 2370, 100, 101, 79, 300, 2370, 30, 51);
  assert(log_count == 65);
}

static void test_pause_resume_and_shutdown(void) {
  reset();
  active(true);
  sample(0, 0, BearingTraceRawValid);
  for (unsigned i = 0; i < 10; i++) frame(i * 30, 100, i, 10, 0);
  active(false);
  fire();
  assert(count_prefix("MAPPY_BTRACE t=") == 4 && timer.armed);
  unsigned prior_logs = log_count;
  active(true);
  assert(!timer.armed && cancellations == 1 && log_count == prior_logs);
  frame(330, 100, 11, 10, 0);
  active(false);
  drain();
  assert(count_prefix("MAPPY_BTRACE t=") == 11);
  assert(count_prefix("MAPPY_BTRACE begin") == 2);
  assert_record(10, 330, 0, 100, 11, 1, 330, 60, BearingTraceRawValid);
  active(true);
  frame(360, 100, 12, 10, 0);
  active(false);
  assert(timer.armed);
  bearing_trace_shutdown();
  assert(!timer.armed);
  prior_logs = log_count;
  active(false);
  assert(!timer.armed && prior_logs == log_count);
}

static void test_wrap_missing_and_saturation(void) {
  reset();
  active(true);
  frame(UINT32_MAX - 20, -1, -1, -72000, BearingTraceFaceForward);
  sample(UINT32_MAX - 10, 35999, BearingTraceRawValid | BearingTraceCalibrated);
  frame(19, 1, -1, 72000, BearingTracePredicting);
  frame(100019, 35999, 0, 72000, 0);
  sample(100020, -1, BearingTraceRawValid | BearingTraceCalibrated);
  frame(100030, 200, 100, 0, BearingTraceReacquiring);
  active(false);
  drain();
  assert_record(0, UINT32_MAX - 20, 65535, 65535, 65535, -7200,
                65535, 0, BearingTraceAgeClamped | BearingTraceFaceForward);
  assert_record(1, 19, 35999, 1, 65535, 7200, 30, 40,
                BearingTraceRawValid | BearingTraceCalibrated | BearingTracePredicting);
  assert_record(2, 100019, 35999, 35999, 0, 7200, 65535, 255,
                BearingTraceRawValid | BearingTraceCalibrated |
                BearingTraceAgeClamped | BearingTraceIntervalClamped);
  assert_record(3, 100030, 65535, 200, 100, 0, 65535, 11,
                BearingTraceAgeClamped | BearingTraceReacquiring);
}

static void test_shared_animations_defer_logging(void) {
  reset();
  active(true);
  sample(0, 0, BearingTraceRawValid);
  for (unsigned i = 0; i < 6; i++) frame(i * 30, 100, i, 100, 0);
  active(false);
  shared_animation_active = true;
  fire();
  fire();
  assert(timer.armed && log_count == 0);
  shared_animation_active = false;
  fire();
  assert(count_prefix("MAPPY_BTRACE t=") == 4 && timer.armed);
  shared_animation_active = true;
  fire();
  assert(count_prefix("MAPPY_BTRACE t=") == 4 && timer.armed);
  shared_animation_active = false;
  drain();
  assert(count_prefix("MAPPY_BTRACE t=") == 6);
}

static void test_timer_failure_retains_data(void) {
  reset();
  active(false);
  assert(registrations == 0);
  active(true);
  sample(10, 100, BearingTraceRawValid);
  frame(40, 100, 50, 100, 0);
  fail_registration = true;
  active(false);
  assert(!timer.armed && log_count == 0 && registrations == 1);
  fail_registration = false;
  active(false);
  assert(timer.armed);
  drain();
  assert(count_prefix("MAPPY_BTRACE t=") == 1);
  assert_record(0, 40, 100, 100, 50, 10, 30, 0, BearingTraceRawValid);
}

int main(void) {
  test_allocation_lifecycle();
  test_ring_and_idle_flush();
  test_pause_resume_and_shutdown();
  test_wrap_missing_and_saturation();
  test_timer_failure_retains_data();
  test_shared_animations_defer_logging();
  bearing_trace_shutdown();
  printf("Bearing trace: ring, bounded idle chunks, pause, wrap, missing data, saturation and timer recovery passed (records=%u bytes)\n",
         (unsigned)(TRACE_CAPACITY * sizeof(BearingTraceRecord)));
  return 0;
}
#endif
