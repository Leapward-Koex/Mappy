#include "mappy.h"

// Fixed-point menu highlight animation with a brief directional overshoot.

#define MENU_MAX_VISIBLE_ROWS 5
#define MENU_HEADER_AND_TOP_PADDING 33
#define MENU_BOTTOM_PADDING 8
#define MENU_ROW_STEP_PX 22
#define MENU_ROW_HEIGHT_PX 21
#define MENU_PANEL_MARGIN_X 6
#define MENU_ROW_MARGIN_X 5
#define MENU_HIGHLIGHT_PROGRESS_MIN 0
#define MENU_HIGHLIGHT_PROGRESS_MAX 65535
#define MENU_HIGHLIGHT_FRAME_INTERVAL_MS 33
#define MENU_HIGHLIGHT_DURATION_MS (MENU_HIGHLIGHT_FRAME_INTERVAL_MS * 7)
#define MENU_HIGHLIGHT_OVERSHOOT_PX 4
#define MENU_HIGHLIGHT_STRETCH_PX 2

static int menu_visible_row_count(void) {
  int count = menu_item_count();
  if (count <= 0) {
    return 0;
  }
  return count < MENU_MAX_VISIBLE_ROWS ? count : MENU_MAX_VISIBLE_ROWS;
}

static GRect menu_panel_rect(void) {
  int visible_rows = menu_visible_row_count();
  int panel_height = MENU_HEADER_AND_TOP_PADDING +
      visible_rows * MENU_ROW_STEP_PX + MENU_BOTTOM_PADDING;
  int panel_y = (s_screen_bounds.size.h - panel_height) / 2;
  if (panel_y < 10) {
    panel_y = 10;
  }
  return GRect(MENU_PANEL_MARGIN_X, panel_y,
               s_screen_bounds.size.w - MENU_PANEL_MARGIN_X * 2,
               panel_height);
}

int menu_first_visible_index_for_selection(int selection) {
  int count = menu_item_count();
  int visible_rows = menu_visible_row_count();
  if (count <= 0 || visible_rows <= 0) {
    return 0;
  }
  if (selection < 0) {
    selection = 0;
  } else if (selection >= count) {
    selection = count - 1;
  }

  int first = selection >= MENU_MAX_VISIBLE_ROWS ?
      selection - MENU_MAX_VISIBLE_ROWS + 1 : 0;
  int max_first = count - visible_rows;
  if (first > max_first) {
    first = max_first;
  }
  return first < 0 ? 0 : first;
}

bool menu_row_rect_for_index_at_first(int item_index, int first, GRect *rect_out) {
  if (!rect_out || s_menu_mode == MenuNone) {
    return false;
  }

  int count = menu_item_count();
  int visible_rows = menu_visible_row_count();
  if (count <= 0 || visible_rows <= 0 ||
      item_index < 0 || item_index >= count ||
      item_index < first || item_index >= first + visible_rows) {
    return false;
  }

  GRect panel = menu_panel_rect();
  int row = item_index - first;
  *rect_out = GRect(panel.origin.x + MENU_ROW_MARGIN_X,
                    panel.origin.y + MENU_HEADER_AND_TOP_PADDING - 2 +
                        row * MENU_ROW_STEP_PX,
                    panel.size.w - MENU_ROW_MARGIN_X * 2,
                    MENU_ROW_HEIGHT_PX);
  return true;
}

static int32_t clamp_animation_progress(int32_t progress_normalized) {
  if (progress_normalized <= MENU_HIGHLIGHT_PROGRESS_MIN) {
    return MENU_HIGHLIGHT_PROGRESS_MIN;
  }
  if (progress_normalized >= MENU_HIGHLIGHT_PROGRESS_MAX) {
    return MENU_HIGHLIGHT_PROGRESS_MAX;
  }
  return progress_normalized;
}

static int32_t scale_animation_interval(int32_t progress_normalized,
                                        int32_t interval_start,
                                        int32_t interval_end) {
  const int32_t clamped = clamp_animation_progress(progress_normalized);
  if (clamped <= interval_start) {
    return MENU_HIGHLIGHT_PROGRESS_MIN;
  }
  if (clamped >= interval_end) {
    return MENU_HIGHLIGHT_PROGRESS_MAX;
  }
  return (int32_t)(((int64_t)(clamped - interval_start) *
                    MENU_HIGHLIGHT_PROGRESS_MAX) /
                   (interval_end - interval_start));
}

static int16_t lerp_i16(int32_t progress_normalized, int16_t from, int16_t to) {
  return (int16_t)(from + (((int32_t)(to - from) * progress_normalized) /
                           MENU_HIGHLIGHT_PROGRESS_MAX));
}

static int32_t lerp_i32(int32_t progress_normalized, int32_t from, int32_t to) {
  return from + (int32_t)(((int64_t)(to - from) * progress_normalized) /
                          MENU_HIGHLIGHT_PROGRESS_MAX);
}

static int32_t abs_i32(int32_t value) {
  return value < 0 ? -value : value;
}

static int32_t menu_highlight_ease_in_out(int32_t progress_normalized) {
  const uint32_t progress =
      (uint32_t)clamp_animation_progress(progress_normalized);
  if (progress <= 32768U) {
    return (int32_t)((progress * progress) >> 15);
  }

  const uint32_t remaining = MENU_HIGHLIGHT_PROGRESS_MAX - progress;
  return MENU_HIGHLIGHT_PROGRESS_MAX -
      (int32_t)((remaining * remaining) >> 15);
}

static uint16_t menu_highlight_elapsed_ms(void) {
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  int32_t elapsed = (int32_t)(now_s - s_menu_highlight_started_s) * 1000 +
      (int32_t)now_ms - (int32_t)s_menu_highlight_started_ms;
  if (elapsed < 0) {
    return 0;
  }
  if (elapsed > UINT16_MAX) {
    return UINT16_MAX;
  }
  return (uint16_t)elapsed;
}

static bool rects_equal(GRect a, GRect b) {
  return a.origin.x == b.origin.x &&
      a.origin.y == b.origin.y &&
      a.size.w == b.size.w &&
      a.size.h == b.size.h;
}

static GRect sample_menu_highlight_rect(uint32_t elapsed_ms) {
  if (elapsed_ms >= MENU_HIGHLIGHT_DURATION_MS) {
    return s_menu_highlight_to_rect;
  }

  const int32_t total_progress =
      (int32_t)(((int64_t)elapsed_ms * MENU_HIGHLIGHT_PROGRESS_MAX) /
                MENU_HIGHLIGHT_DURATION_MS);
  const int32_t eased_total_progress = menu_highlight_ease_in_out(total_progress);
  const int32_t half_progress = MENU_HIGHLIGHT_PROGRESS_MAX / 2;
  const bool second_half = total_progress >= half_progress;
  const int32_t phase_progress = second_half
      ? scale_animation_interval(total_progress, half_progress,
                                 MENU_HIGHLIGHT_PROGRESS_MAX)
      : scale_animation_interval(total_progress, MENU_HIGHLIGHT_PROGRESS_MIN,
                                 half_progress);
  const int32_t eased_phase_progress = menu_highlight_ease_in_out(phase_progress);

  const int32_t from_center_x2 =
      s_menu_highlight_from_rect.origin.x * 2 + s_menu_highlight_from_rect.size.w;
  const int32_t to_center_x2 =
      s_menu_highlight_to_rect.origin.x * 2 + s_menu_highlight_to_rect.size.w;
  const int32_t from_center_y2 =
      s_menu_highlight_from_rect.origin.y * 2 + s_menu_highlight_from_rect.size.h;
  const int32_t to_center_y2 =
      s_menu_highlight_to_rect.origin.y * 2 + s_menu_highlight_to_rect.size.h;
  const bool vertical_motion =
      abs_i32(to_center_y2 - from_center_y2) >=
      abs_i32(to_center_x2 - from_center_x2);

  if (vertical_motion) {
    const int32_t direction =
        (to_center_y2 > from_center_y2) - (to_center_y2 < from_center_y2);
    const int32_t overshoot_center_y2 =
        to_center_y2 + direction * MENU_HIGHLIGHT_OVERSHOOT_PX * 2;
    const int32_t current_center_y2 = second_half
        ? lerp_i32(eased_phase_progress, overshoot_center_y2, to_center_y2)
        : lerp_i32(eased_phase_progress, from_center_y2, overshoot_center_y2);
    const int16_t overshoot_h =
        (int16_t)(s_menu_highlight_to_rect.size.h + MENU_HIGHLIGHT_STRETCH_PX);
    const int16_t h = second_half
        ? lerp_i16(eased_phase_progress, overshoot_h,
                   s_menu_highlight_to_rect.size.h)
        : lerp_i16(eased_phase_progress, s_menu_highlight_from_rect.size.h,
                   overshoot_h);

    return GRect(
        lerp_i16(eased_total_progress, s_menu_highlight_from_rect.origin.x,
                 s_menu_highlight_to_rect.origin.x),
        (int16_t)((current_center_y2 - h) / 2),
        lerp_i16(eased_total_progress, s_menu_highlight_from_rect.size.w,
                 s_menu_highlight_to_rect.size.w),
        h);
  }

  const int32_t direction =
      (to_center_x2 > from_center_x2) - (to_center_x2 < from_center_x2);
  const int32_t overshoot_center_x2 =
      to_center_x2 + direction * MENU_HIGHLIGHT_OVERSHOOT_PX * 2;
  const int32_t current_center_x2 = second_half
      ? lerp_i32(eased_phase_progress, overshoot_center_x2, to_center_x2)
      : lerp_i32(eased_phase_progress, from_center_x2, overshoot_center_x2);
  const int16_t overshoot_w =
      (int16_t)(s_menu_highlight_to_rect.size.w + MENU_HIGHLIGHT_STRETCH_PX);
  const int16_t w = second_half
      ? lerp_i16(eased_phase_progress, overshoot_w,
                 s_menu_highlight_to_rect.size.w)
      : lerp_i16(eased_phase_progress, s_menu_highlight_from_rect.size.w,
                 overshoot_w);

  return GRect(
      (int16_t)((current_center_x2 - w) / 2),
      lerp_i16(eased_total_progress, s_menu_highlight_from_rect.origin.y,
               s_menu_highlight_to_rect.origin.y),
      w,
      lerp_i16(eased_total_progress, s_menu_highlight_from_rect.size.h,
               s_menu_highlight_to_rect.size.h));
}

void cancel_menu_highlight_animation(void) {
  if (s_menu_highlight_timer) {
    app_timer_cancel(s_menu_highlight_timer);
    s_menu_highlight_timer = NULL;
  }
  s_menu_highlight_active = false;
}

void reset_menu_highlight_animation(void) {
  cancel_menu_highlight_animation();
  int first = menu_first_visible_index_for_selection(s_menu_selection);
  if (menu_row_rect_for_index_at_first(s_menu_selection, first,
                                       &s_menu_highlight_to_rect)) {
    s_menu_highlight_from_rect = s_menu_highlight_to_rect;
  }
  s_menu_highlight_from_selection = s_menu_selection;
}

void menu_highlight_timer_callback(void *data) {
  (void)data;
  s_menu_highlight_timer = NULL;
  if (s_menu_highlight_active &&
      menu_highlight_elapsed_ms() >= MENU_HIGHLIGHT_DURATION_MS) {
    s_menu_highlight_active = false;
  }
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
  if (s_menu_highlight_active && s_menu_mode != MenuNone) {
    s_menu_highlight_timer = app_timer_register(MENU_HIGHLIGHT_FRAME_INTERVAL_MS,
                                                menu_highlight_timer_callback, NULL);
  }
}

static void schedule_menu_highlight_tick(void) {
  if (!s_menu_highlight_timer && s_menu_highlight_active && s_menu_mode != MenuNone) {
    s_menu_highlight_timer = app_timer_register(MENU_HIGHLIGHT_FRAME_INTERVAL_MS,
                                                menu_highlight_timer_callback, NULL);
  }
}

void start_menu_highlight_animation(int previous_selection, int direction) {
  if (s_menu_mode == MenuNone || previous_selection == s_menu_selection) {
    reset_menu_highlight_animation();
    return;
  }

  int target_first = menu_first_visible_index_for_selection(s_menu_selection);
  GRect from_rect;
  GRect to_rect;
  if (!menu_row_rect_for_index_at_first(s_menu_selection, target_first, &to_rect)) {
    reset_menu_highlight_animation();
    return;
  }
  if (!menu_row_rect_for_index_at_first(previous_selection, target_first, &from_rect)) {
    from_rect = to_rect;
    from_rect.origin.y -= (int16_t)(direction * MENU_ROW_STEP_PX);
  }
  if (rects_equal(from_rect, to_rect)) {
    from_rect.origin.y -= (int16_t)(direction * MENU_ROW_STEP_PX);
  }

  cancel_menu_highlight_animation();
  s_menu_highlight_from_rect = from_rect;
  s_menu_highlight_to_rect = to_rect;
  s_menu_highlight_from_selection = previous_selection;
  time_ms(&s_menu_highlight_started_s, &s_menu_highlight_started_ms);
  s_menu_highlight_active = true;
  schedule_menu_highlight_tick();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void start_menu_value_animation(int direction) {
  if (s_menu_mode == MenuNone) {
    return;
  }

  int first = menu_first_visible_index_for_selection(s_menu_selection);
  GRect target_rect;
  if (!menu_row_rect_for_index_at_first(s_menu_selection, first, &target_rect)) {
    reset_menu_highlight_animation();
    return;
  }

  if (direction == 0) {
    direction = 1;
  }
  GRect from_rect = target_rect;
  from_rect.origin.x += (int16_t)(direction * MENU_HIGHLIGHT_OVERSHOOT_PX);

  cancel_menu_highlight_animation();
  s_menu_highlight_from_rect = from_rect;
  s_menu_highlight_to_rect = target_rect;
  s_menu_highlight_from_selection = s_menu_selection;
  time_ms(&s_menu_highlight_started_s, &s_menu_highlight_started_ms);
  s_menu_highlight_active = true;
  schedule_menu_highlight_tick();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

bool menu_highlight_rect(GRect *rect_out) {
  if (!rect_out || s_menu_mode == MenuNone) {
    return false;
  }

  int first = menu_first_visible_index_for_selection(s_menu_selection);
  GRect target_rect;
  if (!menu_row_rect_for_index_at_first(s_menu_selection, first, &target_rect)) {
    return false;
  }
  if (!s_menu_highlight_active) {
    *rect_out = target_rect;
    return true;
  }

  uint16_t elapsed_ms = menu_highlight_elapsed_ms();
  if (elapsed_ms >= MENU_HIGHLIGHT_DURATION_MS) {
    s_menu_highlight_active = false;
    s_menu_highlight_to_rect = target_rect;
    *rect_out = target_rect;
    return true;
  }

  *rect_out = sample_menu_highlight_rect(elapsed_ms);
  return true;
}

int menu_highlight_text_index(GRect highlight_rect, int first) {
  int count = menu_item_count();
  int visible_rows = menu_visible_row_count();
  int center_y = highlight_rect.origin.y + highlight_rect.size.h / 2;
  for (int row = 0; row < visible_rows && first + row < count; row++) {
    GRect row_rect;
    int item_index = first + row;
    if (!menu_row_rect_for_index_at_first(item_index, first, &row_rect)) {
      continue;
    }
    if (center_y >= row_rect.origin.y &&
        center_y < row_rect.origin.y + MENU_ROW_STEP_PX) {
      return item_index;
    }
  }
  return s_menu_selection;
}
