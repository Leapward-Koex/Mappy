#include "navigation_feedback.h"

int navigation_feedback_normalize_mode(int mode) {
  switch (mode) {
    case NavigationFeedbackModeOff:
    case NavigationFeedbackModeTurns:
    case NavigationFeedbackModeArrival:
    case NavigationFeedbackModeAll:
      return mode;
    default:
      return NavigationFeedbackModeAll;
  }
}

int navigation_feedback_next_mode(int mode) {
  switch (navigation_feedback_normalize_mode(mode)) {
    case NavigationFeedbackModeAll:
      return NavigationFeedbackModeTurns;
    case NavigationFeedbackModeTurns:
      return NavigationFeedbackModeArrival;
    case NavigationFeedbackModeArrival:
      return NavigationFeedbackModeOff;
    case NavigationFeedbackModeOff:
    default:
      return NavigationFeedbackModeAll;
  }
}

bool navigation_feedback_mode_allows_event(int mode,
                                           NavigationFeedbackEvent event) {
  int normalized_mode = navigation_feedback_normalize_mode(mode);
  switch (event) {
    case NavigationFeedbackEventRouteStart:
      return normalized_mode == NavigationFeedbackModeAll;
    case NavigationFeedbackEventTurnPreview:
    case NavigationFeedbackEventTurnNow:
      return (normalized_mode & NavigationFeedbackModeTurns) != 0;
    case NavigationFeedbackEventArrival:
      return (normalized_mode & NavigationFeedbackModeArrival) != 0;
    default:
      return false;
  }
}
