#include <stdbool.h>
#include <stdio.h>

#include "../apps/pebble-watch/src/c/navigation_feedback.h"

static int s_failures;

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: %s\n", message); \
    s_failures++; \
  } \
} while (0)

static void test_feedback_matrix(void) {
  static const bool expected[4][4] = {
    [NavigationFeedbackModeOff] = {false, false, false, false},
    [NavigationFeedbackModeTurns] = {false, true, true, false},
    [NavigationFeedbackModeArrival] = {false, false, false, true},
    [NavigationFeedbackModeAll] = {true, true, true, true},
  };

  for (int mode = NavigationFeedbackModeOff;
       mode <= NavigationFeedbackModeAll; mode++) {
    for (int event = NavigationFeedbackEventRouteStart;
         event <= NavigationFeedbackEventArrival; event++) {
      bool actual = navigation_feedback_mode_allows_event(
          mode, (NavigationFeedbackEvent)event);
      if (actual != expected[mode][event]) {
        fprintf(stderr, "FAIL: mode=%d event=%d expected=%d actual=%d\n",
                mode, event, expected[mode][event] ? 1 : 0,
                actual ? 1 : 0);
        s_failures++;
      }
    }
  }
}

static void test_mode_normalization(void) {
  CHECK(navigation_feedback_normalize_mode(-1) == NavigationFeedbackModeAll,
        "negative mode must normalize to All");
  CHECK(navigation_feedback_normalize_mode(4) == NavigationFeedbackModeAll,
        "mode above the wire range must normalize to All");
  CHECK(navigation_feedback_mode_allows_event(
            99, NavigationFeedbackEventRouteStart),
        "invalid mode must use the All event policy");
  CHECK(!navigation_feedback_mode_allows_event(
             NavigationFeedbackModeAll, (NavigationFeedbackEvent)99),
        "invalid event must never produce feedback");
}

static void test_watch_menu_cycle(void) {
  int mode = NavigationFeedbackModeAll;
  mode = navigation_feedback_next_mode(mode);
  CHECK(mode == NavigationFeedbackModeTurns, "All must cycle to Turns");
  mode = navigation_feedback_next_mode(mode);
  CHECK(mode == NavigationFeedbackModeArrival, "Turns must cycle to Arrival");
  mode = navigation_feedback_next_mode(mode);
  CHECK(mode == NavigationFeedbackModeOff, "Arrival must cycle to Off");
  mode = navigation_feedback_next_mode(mode);
  CHECK(mode == NavigationFeedbackModeAll, "Off must cycle to All");
}

int main(void) {
  test_feedback_matrix();
  test_mode_normalization();
  test_watch_menu_cycle();
  if (s_failures != 0) {
    fprintf(stderr, "navigation feedback tests: %d failure(s)\n", s_failures);
    return 1;
  }
  printf("navigation feedback tests: all checks passed\n");
  return 0;
}
