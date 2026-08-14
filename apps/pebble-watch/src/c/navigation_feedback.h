#ifndef NAVIGATION_FEEDBACK_H
#define NAVIGATION_FEEDBACK_H

#include <stdbool.h>

typedef enum {
  NavigationFeedbackModeOff = 0,
  NavigationFeedbackModeTurns = 1,
  NavigationFeedbackModeArrival = 2,
  NavigationFeedbackModeAll = 3,
} NavigationFeedbackMode;

typedef enum {
  NavigationFeedbackEventRouteStart = 0,
  NavigationFeedbackEventTurnPreview,
  NavigationFeedbackEventTurnNow,
  NavigationFeedbackEventArrival,
} NavigationFeedbackEvent;

int navigation_feedback_normalize_mode(int mode);
int navigation_feedback_next_mode(int mode);
bool navigation_feedback_mode_allows_event(int mode,
                                           NavigationFeedbackEvent event);

#endif
