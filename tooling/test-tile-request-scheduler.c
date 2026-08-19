#include <stdio.h>

#include "tile-requests-host-shim.h"

struct AppTimer {
  uint32_t delay_ms;
  uint64_t due_ms;
  AppTimerCallback callback;
  void *context;
  bool active;
};

TileRequest s_request_queue[TILE_CACHE_SIZE];
uint8_t s_request_retry_attempts[TILE_CACHE_SIZE];
int s_request_count;
int s_request_index;
int32_t s_inflight_tile_request_id;
TileFlight s_tile_flights[TILE_REQUEST_MAX_FLIGHTS];
bool s_tile_requests_interaction_paused;
bool s_tile_requests_setup_paused;
AppTimer *s_tile_request_resume_timer;
AppTimer *s_tile_redraw_timer;
bool s_tile_redraw_deferred;
TileCoverageEnvelope s_render_tile_envelope;
AppTimer *s_tile_request_watchdog_timer;
bool s_outbox_busy;
int32_t s_outbox_cmd;
int32_t s_next_request_id;
int s_theme_mode;
bool s_has_gps;
GRect s_screen_bounds;
Layer *s_map_layer;
TileCacheEntry *s_tiles;
bool s_tile_chunk_active;
int32_t s_tile_chunk_request_id;

static int s_failures;
static uint64_t s_now_ms;
static AppTimer s_timers[16];
static TileRequest s_visible_origins[TILE_CACHE_SIZE];
static int s_visible_origin_count;
static TileRequest s_request_origins[TILE_CACHE_SIZE];
static int s_request_origin_count;
static bool s_visible_grid_missing;
static bool s_control_pending;
static int s_control_send_count;
static int s_tile_send_count;
static int s_chunk_reset_count;
static int s_dirty_count;
static AppMessageResult s_send_begin_result;
static AppMessageResult s_outbox_send_result;
static DictionaryIterator s_dictionary;
static Layer s_layer;
static bool s_rendering_visible;

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: %s\n", message); \
    s_failures++; \
  } \
} while (0)

AppTimer *app_timer_register(uint32_t timeout_ms, AppTimerCallback callback,
                             void *context) {
  for (size_t i = 0; i < sizeof(s_timers) / sizeof(s_timers[0]); i++) {
    if (!s_timers[i].active) {
      s_timers[i] = (AppTimer) {
        .delay_ms = timeout_ms,
        .due_ms = s_now_ms + timeout_ms,
        .callback = callback,
        .context = context,
        .active = true,
      };
      return &s_timers[i];
    }
  }
  return NULL;
}

void app_timer_cancel(AppTimer *timer) {
  if (timer) {
    timer->active = false;
  }
}

void time_ms(time_t *seconds, uint16_t *milliseconds) {
  *seconds = (time_t)(s_now_ms / 1000);
  *milliseconds = (uint16_t)(s_now_ms % 1000);
}

void layer_mark_dirty(Layer *layer) {
  if (layer) {
    s_dirty_count++;
  }
}

bool map_bearing_rendering_visible(void) {
  return s_rendering_visible;
}

int active_tile_cache_size(void) {
  return TILE_CACHE_SIZE;
}

TileCacheEntry *find_tile(int32_t world_x, int32_t world_y, int8_t zoom) {
  if (!s_tiles) {
    return NULL;
  }
  for (int i = 0; i < TILE_CACHE_SIZE; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (entry->world_x == world_x && entry->world_y == world_y &&
        entry->zoom == zoom) {
      return entry;
    }
  }
  return NULL;
}

bool tile_coordinates_visible(int32_t world_x, int32_t world_y, int8_t zoom) {
  for (int i = 0; i < s_request_origin_count; i++) {
    TileRequest *origin = &s_request_origins[i];
    if (origin->world_x == world_x && origin->world_y == world_y &&
        origin->zoom == zoom) {
      return true;
    }
  }
  return false;
}

bool tile_coordinates_render_visible(int32_t world_x, int32_t world_y,
                                     int8_t zoom) {
  return tile_origin_list_contains(s_visible_origins, s_visible_origin_count,
                                   world_x, world_y, zoom);
}

bool tile_coverage_envelope_contains(const TileCoverageEnvelope *envelope,
                                     int32_t world_x, int32_t world_y,
                                     int8_t zoom) {
  return envelope && envelope->valid && zoom == envelope->zoom &&
      world_x >= envelope->start_x && world_x <= envelope->end_x &&
      world_y >= envelope->start_y && world_y <= envelope->end_y;
}

bool tile_is_visible(const TileCacheEntry *entry) {
  return entry && tile_coordinates_render_visible(
                      entry->world_x, entry->world_y, entry->zoom);
}

void refresh_render_tile_coverage(void) {
  if (s_visible_origin_count > 0) {
    s_render_tile_envelope = (TileCoverageEnvelope) {
      .start_x = s_visible_origins[0].world_x,
      .end_x = s_visible_origins[0].world_x,
      .start_y = s_visible_origins[0].world_y,
      .end_y = s_visible_origins[0].world_y,
      .zoom = s_visible_origins[0].zoom,
      .valid = true,
    };
    for (int i = 1; i < s_visible_origin_count; i++) {
      if (s_visible_origins[i].world_x < s_render_tile_envelope.start_x) {
        s_render_tile_envelope.start_x = s_visible_origins[i].world_x;
      }
      if (s_visible_origins[i].world_x > s_render_tile_envelope.end_x) {
        s_render_tile_envelope.end_x = s_visible_origins[i].world_x;
      }
      if (s_visible_origins[i].world_y < s_render_tile_envelope.start_y) {
        s_render_tile_envelope.start_y = s_visible_origins[i].world_y;
      }
      if (s_visible_origins[i].world_y > s_render_tile_envelope.end_y) {
        s_render_tile_envelope.end_y = s_visible_origins[i].world_y;
      }
    }
  } else {
    s_render_tile_envelope.valid = false;
  }
}

int visible_tile_origins(TileRequest *origins, int max_count) {
  int count = s_visible_origin_count < max_count ? s_visible_origin_count :
                                                  max_count;
  memcpy(origins, s_visible_origins, (size_t)count * sizeof(*origins));
  refresh_render_tile_coverage();
  return count;
}

int request_tile_origins(TileRequest *origins, int max_count) {
  int count = s_request_origin_count < max_count ? s_request_origin_count :
                                                  max_count;
  memcpy(origins, s_request_origins, (size_t)count * sizeof(*origins));
  return count;
}

bool tile_origin_list_contains(const TileRequest *origins, int count,
                               int32_t world_x, int32_t world_y, int8_t zoom) {
  for (int i = 0; i < count; i++) {
    if (origins[i].world_x == world_x && origins[i].world_y == world_y &&
        origins[i].zoom == zoom) {
      return true;
    }
  }
  return false;
}

bool map_orientation_active(void) {
  return false;
}

void invalidate_orientation_tile_coverage(void) {
}

bool visible_grid_has_missing_tiles(void) {
  return s_visible_grid_missing;
}

void reset_tile_chunk_assembly(void) {
  s_tile_chunk_active = false;
  s_tile_chunk_request_id = 0;
  s_chunk_reset_count++;
}

void queue_log_event(int category, int detail, int detail2, const char *text) {
  (void)category;
  (void)detail;
  (void)detail2;
  (void)text;
}

bool send_deferred_route_action(void) {
  if (!s_control_pending) {
    return false;
  }
  s_control_send_count++;
  s_outbox_busy = true;
  s_outbox_cmd = 207;
  return true;
}

AppMessageResult send_message_begin(DictionaryIterator **iter, int32_t cmd) {
  if (s_send_begin_result != APP_MSG_OK) {
    return s_send_begin_result;
  }
  if (s_outbox_busy) {
    return 1;
  }
  s_outbox_busy = true;
  s_outbox_cmd = cmd;
  *iter = &s_dictionary;
  return APP_MSG_OK;
}

void write_i32(DictionaryIterator *iter, uint32_t key, int32_t value) {
  (void)iter;
  (void)key;
  (void)value;
}

AppMessageResult app_message_outbox_send(void) {
  if (s_outbox_send_result == APP_MSG_OK) {
    s_tile_send_count++;
  }
  return s_outbox_send_result;
}

static void set_visible_origins(int count) {
  s_visible_origin_count = count;
  s_request_origin_count = count;
  for (int i = 0; i < count; i++) {
    s_visible_origins[i] = (TileRequest) {
      .world_x = i * 54,
      .world_y = 0,
      .zoom = 16,
    };
    s_request_origins[i] = s_visible_origins[i];
  }
}

static void cancel_remaining_timers(void) {
  cancel_all_tile_requests();
  cancel_tile_redraw();
  if (s_tile_request_resume_timer) {
    app_timer_cancel(s_tile_request_resume_timer);
    s_tile_request_resume_timer = NULL;
  }
}

static void reset_fixture(void) {
  cancel_remaining_timers();
  memset(s_timers, 0, sizeof(s_timers));
  memset(s_request_queue, 0, sizeof(s_request_queue));
  memset(s_request_retry_attempts, 0, sizeof(s_request_retry_attempts));
  memset(s_tile_flights, 0, sizeof(s_tile_flights));
  s_request_count = 0;
  s_request_index = 0;
  s_inflight_tile_request_id = 0;
  s_tile_requests_interaction_paused = false;
  s_tile_requests_setup_paused = false;
  s_tile_request_resume_timer = NULL;
  s_tile_redraw_timer = NULL;
  s_tile_redraw_deferred = false;
  memset(&s_render_tile_envelope, 0, sizeof(s_render_tile_envelope));
  s_tile_request_watchdog_timer = NULL;
  s_outbox_busy = false;
  s_outbox_cmd = 0;
  s_next_request_id = 1;
  s_theme_mode = 0;
  s_has_gps = true;
  s_screen_bounds.size.w = 200;
  s_screen_bounds.size.h = 200;
  s_map_layer = &s_layer;
  s_tiles = NULL;
  s_tile_chunk_active = false;
  s_tile_chunk_request_id = 0;
  s_visible_origin_count = 0;
  s_request_origin_count = 0;
  s_visible_grid_missing = false;
  s_control_pending = false;
  s_control_send_count = 0;
  s_tile_send_count = 0;
  s_chunk_reset_count = 0;
  s_dirty_count = 0;
  s_rendering_visible = true;
  s_send_begin_result = APP_MSG_OK;
  s_outbox_send_result = APP_MSG_OK;
  s_now_ms = 10000;
}

static void acknowledge_outbox(void) {
  int32_t completed_cmd = s_outbox_cmd;
  s_outbox_busy = false;
  s_outbox_cmd = 0;
  if (completed_cmd == CMD_TILE_REQUEST) {
    s_inflight_tile_request_id = 0;
  }
  if (!send_deferred_route_action()) {
    send_next_tile_request();
  }
}

static int active_retry_timer_count(void) {
  int count = 0;
  for (size_t i = 0; i < sizeof(s_timers) / sizeof(s_timers[0]); i++) {
    if (s_timers[i].active && s_timers[i].context) {
      count++;
    }
  }
  return count;
}

static TileFlight *find_flight_for_coordinate(int32_t world_x,
                                              int32_t world_y, int8_t zoom) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    TileFlight *flight = &s_tile_flights[i];
    if (flight->active && flight->request.world_x == world_x &&
        flight->request.world_y == world_y && flight->request.zoom == zoom) {
      return flight;
    }
  }
  return NULL;
}

static void advance_time(uint32_t delta_ms) {
  uint64_t target = s_now_ms + delta_ms;
  for (;;) {
    AppTimer *next = NULL;
    for (size_t i = 0; i < sizeof(s_timers) / sizeof(s_timers[0]); i++) {
      if (s_timers[i].active && s_timers[i].due_ms <= target &&
          (!next || s_timers[i].due_ms < next->due_ms)) {
        next = &s_timers[i];
      }
    }
    if (!next) {
      break;
    }
    s_now_ms = next->due_ms;
    AppTimerCallback callback = next->callback;
    void *context = next->context;
    next->active = false;
    callback(context);
  }
  s_now_ms = target;
}

static void test_two_flight_window_and_ack_semantics(void) {
  reset_fixture();
  set_visible_origins(3);

  queue_visible_tiles();
  CHECK(active_tile_flight_count() == 1,
        "first request should allocate one response flight");
  CHECK(s_tile_send_count == 1, "first tile request should be sent");
  int32_t first_id = s_tile_flights[0].request_id;

  acknowledge_outbox();
  CHECK(active_tile_flight_count() == 2,
        "outbox ACK should open the second response slot");
  CHECK(find_tile_flight(0, 0, 16, first_id) != NULL,
        "outbox ACK must not retire the first response flight");
  CHECK(s_tile_send_count == 2, "second tile request should be sent");

  acknowledge_outbox();
  CHECK(active_tile_flight_count() == TILE_REQUEST_MAX_FLIGHTS,
        "response window must remain capped at two flights");
  CHECK(s_tile_send_count == 2,
        "a third request must wait for a terminal response");

  TileFlight *first = find_tile_flight(0, 0, 16, first_id);
  complete_tile_flight(first);
  CHECK(active_tile_flight_count() == 2,
        "terminal response should retire one flight and fill its slot");
  CHECK(s_tile_send_count == 3,
        "third request should start only after a terminal response");
}

static void test_control_message_priority(void) {
  reset_fixture();
  set_visible_origins(1);
  s_control_pending = true;

  queue_visible_tiles();
  CHECK(s_control_send_count == 1,
        "deferred control message should be attempted before tile work");
  CHECK(s_tile_send_count == 0 && active_tile_flight_count() == 0,
        "control traffic should prevent tile dispatch in the same slot");

  s_control_pending = false;
  acknowledge_outbox();
  CHECK(s_tile_send_count == 1 && active_tile_flight_count() == 1,
        "tile dispatch should resume after the control ACK");
}

static void test_outbox_failure_preserves_next_request_correlation(void) {
  reset_fixture();
  set_visible_origins(2);
  queue_visible_tiles();
  int32_t failed_id = s_inflight_tile_request_id;

  // Match protocol.c: release the failed AppMessage slot before asking the
  // scheduler to retire/retry its response flight.
  s_outbox_busy = false;
  s_outbox_cmd = 0;
  handle_tile_request_outbox_failure((AppMessageResult)1);

  TileFlight *next = find_flight_for_coordinate(54, 0, 16);
  CHECK(next != NULL && next->request_id != failed_id,
        "an outbox failure should open the response slot for the next tile");
  CHECK(next && s_inflight_tile_request_id == next->request_id,
        "retiring the failed flight must not erase the next outbox request ID");

  int32_t next_id = next ? next->request_id : 0;
  s_outbox_busy = false;
  s_outbox_cmd = 0;
  handle_tile_request_outbox_failure((AppMessageResult)1);
  CHECK(find_tile_flight(54, 0, 16, next_id) == NULL,
        "a consecutive outbox failure should correlate to the replacement flight");
}

static void test_decode_suppression_covers_the_visible_grid(void) {
  reset_fixture();
  suppress_tile_request(0, 0, 16);
  suppress_tile_request(54, 0, 16);
  suppress_tile_request(108, 0, 16);

  CHECK(tile_request_is_suppressed(0, 0, 16) &&
            tile_request_is_suppressed(54, 0, 16) &&
            tile_request_is_suppressed(108, 0, 16),
        "three deterministic decode failures must remain suppressed together");

  set_visible_origins(2);
  clear_offscreen_pending_tile_requests();
  CHECK(tile_request_is_suppressed(0, 0, 16) &&
            tile_request_is_suppressed(54, 0, 16) &&
            !tile_request_is_suppressed(108, 0, 16),
        "suppression should clear only after a failed coordinate leaves view");
}

static void test_unsent_begin_failure_retries_without_external_input(void) {
  reset_fixture();
  set_visible_origins(1);
  s_send_begin_result = (AppMessageResult)1;

  queue_visible_tiles();
  CHECK(active_tile_flight_count() == 0 && s_tile_send_count == 0,
        "an AppMessage begin failure must not allocate a response flight");
  CHECK(s_tile_request_watchdog_timer != NULL,
        "unsent tile work should arm a dispatch retry timer");

  s_send_begin_result = APP_MSG_OK;
  advance_time(TILE_REQUEST_WATCHDOG_MS - 1);
  CHECK(s_tile_send_count == 0,
        "unsent dispatch retry should wait for its timer");
  advance_time(1);
  CHECK(s_tile_send_count == 1 && active_tile_flight_count() == 1,
        "unsent tile work should retry without GPS or user input");
}

static void test_ready_retry_attempt_survives_queue_rebuild(void) {
  reset_fixture();
  set_visible_origins(3);
  queue_visible_tiles();
  acknowledge_outbox();
  acknowledge_outbox();

  TileFlight *first = find_flight_for_coordinate(0, 0, 16);
  retry_tile_flight(first, false);
  CHECK(find_flight_for_coordinate(108, 0, 16) == NULL,
        "regular work must reserve backoff capacity for the remaining flight");

  TileFlight *second = find_flight_for_coordinate(54, 0, 16);
  complete_tile_flight(second);
  CHECK(find_flight_for_coordinate(108, 0, 16) != NULL,
        "regular work may proceed when retry metadata still covers all flights");

  advance_time(1000);
  CHECK(find_flight_for_coordinate(0, 0, 16) == NULL,
        "a ready retry should wait while the AppMessage outbox is busy");
  queue_visible_tiles();

  acknowledge_outbox();
  TileFlight *retried = find_flight_for_coordinate(0, 0, 16);
  CHECK(retried && retried->retry_attempt == 1,
        "queue rebuilding must preserve the retry backoff attempt");
}

static void test_touchdown_retires_flights_and_clears_queue(void) {
  reset_fixture();
  set_visible_origins(3);
  queue_visible_tiles();
  acknowledge_outbox();
  acknowledge_outbox();
  int32_t first_id = s_tile_flights[0].request_id;
  int32_t second_id = s_tile_flights[1].request_id;
  s_tile_chunk_active = true;
  s_tile_chunk_request_id = first_id;

  pause_tile_requests_for_interaction();
  CHECK(tile_requests_paused(), "touchdown should pause tile dispatch");
  CHECK(s_request_count == 0 && s_request_index == 0,
        "touchdown should clear every unsent request");
  CHECK(active_tile_flight_count() == 0,
        "touchdown should immediately free both obsolete response slots");
  CHECK(s_tile_request_watchdog_timer == NULL,
        "touchdown should cancel the obsolete-flight watchdog");
  CHECK(!s_tile_chunk_active && s_chunk_reset_count > 0,
        "touchdown should reset partial tile decoding");
  CHECK(find_tile_flight(0, 0, 16, first_id) == NULL &&
            find_tile_flight(54, 0, 16, second_id) == NULL,
        "retired request IDs must stop matching before terminal data arrives");
  CHECK(s_next_request_id > first_id && s_next_request_id > second_id,
        "retiring flights must not rewind the request ID sequence");
}

static void test_pause_resume_replaces_flights_and_ignores_late_chunks(void) {
  reset_fixture();
  set_visible_origins(2);
  queue_visible_tiles();
  acknowledge_outbox();
  acknowledge_outbox();

  TileFlight *old_first = find_flight_for_coordinate(0, 0, 16);
  TileFlight *old_second = find_flight_for_coordinate(54, 0, 16);
  int32_t old_first_id = old_first ? old_first->request_id : 0;
  int32_t old_second_id = old_second ? old_second->request_id : 0;
  CHECK(old_first_id > 0 && old_second_id > 0,
        "the pause regression requires two live response flights");

  pause_tile_requests_for_interaction();
  CHECK(active_tile_flight_count() == 0,
        "pause should retire both live flights without waiting eight seconds");
  resume_tile_requests_after_interaction();
  advance_time(TILE_REQUEST_TOUCH_RESUME_MS);
  acknowledge_outbox();
  acknowledge_outbox();

  TileFlight *new_first = find_flight_for_coordinate(0, 0, 16);
  TileFlight *new_second = find_flight_for_coordinate(54, 0, 16);
  int32_t new_first_id = new_first ? new_first->request_id : 0;
  int32_t new_second_id = new_second ? new_second->request_id : 0;
  CHECK(new_first_id > old_second_id && new_second_id > old_second_id,
        "resumed requests must receive fresh, monotonically increasing IDs");
  CHECK(active_tile_flight_count() == 2,
        "resume should refill both response slots for the current viewport");

  // tile_decode.c performs this exact lookup before accepting any chunk. A
  // terminal chunk from either retired flight must therefore remain ignored,
  // even when a replacement for the same coordinate is active.
  TileFlight *late_first = find_tile_flight(0, 0, 16, old_first_id);
  TileFlight *late_second = find_tile_flight(54, 0, 16, old_second_id);
  CHECK(late_first == NULL && late_second == NULL,
        "late terminal chunks must not match replacement flights");
  if (late_first) {
    complete_tile_flight(late_first);
  }
  if (late_second) {
    complete_tile_flight(late_second);
  }
  CHECK(active_tile_flight_count() == 2 &&
            find_tile_flight(0, 0, 16, new_first_id) != NULL &&
            find_tile_flight(54, 0, 16, new_second_id) != NULL,
        "late terminal chunks must not retire current-viewport flights");

  handle_tile_request_error(0, 0, 16, old_first_id, false, true);
  handle_tile_request_error(54, 0, 16, old_second_id, false, true);
  CHECK(active_tile_flight_count() == 2 && active_retry_timer_count() == 0,
        "late terminal errors must also leave replacement flights untouched");
}

static void test_resume_waits_full_grace_period(void) {
  reset_fixture();
  set_visible_origins(1);
  pause_tile_requests_for_interaction();
  resume_tile_requests_after_interaction();

  CHECK(s_tile_request_resume_timer != NULL,
        "liftoff should arm a resume timer");
  CHECK(s_tile_request_resume_timer->delay_ms == TILE_REQUEST_TOUCH_RESUME_MS,
        "liftoff grace timer should be exactly 100ms");
  advance_time(TILE_REQUEST_TOUCH_RESUME_MS - 1);
  CHECK(tile_requests_paused() && s_tile_send_count == 0,
        "tile dispatch must remain paused through 99ms");
  advance_time(1);
  CHECK(!tile_requests_paused() && s_tile_send_count == 1,
        "tile dispatch should resume at the 100ms boundary");
}

static void test_interrupting_touchdown_restarts_resume_grace_once(void) {
  reset_fixture();
  set_visible_origins(1);
  pause_tile_requests_for_interaction();
  resume_tile_requests_after_interaction();

  AppTimer *interrupted_resume = s_tile_request_resume_timer;
  CHECK(interrupted_resume != NULL,
        "the interrupted release should initially arm a resume timer");
  advance_time(40);

  // Equivalent to a new touchdown while the previous interaction is waiting
  // to resume tile work: cancel that resume and inherit the paused state.
  pause_tile_requests_for_interaction();
  CHECK(tile_requests_paused() && s_tile_send_count == 0,
        "an interrupting touchdown must keep tile dispatch paused");
  CHECK(s_tile_request_resume_timer == NULL,
        "an interrupting touchdown should clear the pending resume timer");
  CHECK(interrupted_resume && !interrupted_resume->active,
        "the interrupted resume callback must be canceled");
  queue_visible_tiles();
  CHECK(s_request_count == 0 && s_tile_send_count == 0,
        "coverage rebuilds must remain deferred throughout interaction pause");

  advance_time(TILE_REQUEST_TOUCH_RESUME_MS);
  CHECK(tile_requests_paused() && s_tile_send_count == 0,
        "the canceled resume must not start requests at its old deadline");

  resume_tile_requests_after_interaction();
  CHECK(s_tile_request_resume_timer != NULL &&
            s_tile_request_resume_timer->due_ms ==
                s_now_ms + TILE_REQUEST_TOUCH_RESUME_MS,
        "the settled replacement interaction should start a fresh full "
        "grace period");
  advance_time(TILE_REQUEST_TOUCH_RESUME_MS - 1);
  CHECK(tile_requests_paused() && s_tile_send_count == 0,
        "replacement tile work must stay paused through its full grace period");
  advance_time(1);
  CHECK(!tile_requests_paused() && s_tile_request_resume_timer == NULL &&
            s_tile_send_count == 1 && active_tile_flight_count() == 1,
        "replacement tile work should start exactly once at the grace "
        "boundary");

  advance_time(TILE_REQUEST_TOUCH_RESUME_MS);
  CHECK(s_tile_send_count == 1 && active_tile_flight_count() == 1,
        "no stale resume callback may start duplicate tile work");
}

static void test_timeout_retry_isolated_from_other_flight(void) {
  reset_fixture();
  set_visible_origins(2);
  queue_visible_tiles();
  acknowledge_outbox();
  acknowledge_outbox();
  TileFlight *expired = find_flight_for_coordinate(0, 0, 16);
  TileFlight *fresh = find_flight_for_coordinate(54, 0, 16);
  int32_t expired_id = expired->request_id;
  int32_t fresh_id = fresh->request_id;
  expired->started_s = (time_t)((s_now_ms - TILE_REQUEST_STALE_MS - 1) / 1000);
  expired->started_ms = 0;

  CHECK(expire_stale_tile_requests(), "stale flight should expire");
  CHECK(find_tile_flight(0, 0, 16, expired_id) == NULL,
        "expired flight should immediately leave the response window");
  CHECK(find_tile_flight(54, 0, 16, fresh_id) != NULL,
        "an unrelated fresh flight must remain active");
  CHECK(active_retry_timer_count() == 1,
        "expired coordinate should wait outside the response window");
  CHECK(active_tile_flight_count() == 1,
        "retry backoff must not consume a response slot");

  advance_time(999);
  CHECK(find_flight_for_coordinate(0, 0, 16) == NULL,
        "retry should not dispatch before its one-second backoff");
  advance_time(1);
  TileFlight *retried = find_flight_for_coordinate(0, 0, 16);
  CHECK(retried && retried->request_id != expired_id,
        "retry should dispatch with a new request ID after backoff");
  CHECK(find_tile_flight(54, 0, 16, fresh_id) != NULL,
        "retry dispatch must not disturb the other flight");
  CHECK(active_tile_flight_count() == 2,
        "retried request should use the newly free response slot");
}

static void test_discard_timeout_does_not_retry(void) {
  reset_fixture();
  set_visible_origins(1);
  queue_visible_tiles();
  acknowledge_outbox();
  TileFlight *flight = find_flight_for_coordinate(0, 0, 16);
  flight->discard_only = true;
  flight->started_s = (time_t)((s_now_ms - TILE_REQUEST_STALE_MS - 1) / 1000);
  flight->started_ms = 0;

  CHECK(expire_stale_tile_requests(), "discard-only timeout should retire");
  CHECK(active_tile_flight_count() == 0,
        "discard-only timeout should free its response slot");
  CHECK(active_retry_timer_count() == 0,
        "discard-only timeout must not schedule a retry");
}

static void test_tile_error_requires_exact_request_id(void) {
  reset_fixture();
  set_visible_origins(1);
  queue_visible_tiles();
  acknowledge_outbox();
  TileFlight *flight = find_flight_for_coordinate(0, 0, 16);
  int32_t request_id = flight->request_id;

  handle_tile_request_error(0, 0, 16, 0, false, true);
  handle_tile_request_error(0, 0, 16, request_id + 1, false, true);
  CHECK(find_tile_flight(0, 0, 16, request_id) != NULL,
        "missing or stale tile errors must not retire the current flight");
  CHECK(active_retry_timer_count() == 0,
        "missing or stale tile errors must not schedule a retry");

  handle_tile_request_error(0, 0, 16, request_id, false, true);
  CHECK(find_tile_flight(0, 0, 16, request_id) == NULL,
        "the exact matching tile error should retire its flight");
  CHECK(active_retry_timer_count() == 1,
        "the exact matching retryable error should schedule one retry");
}

static void test_tile_redraw_defers_behind_overlay(void) {
  reset_fixture();
  s_rendering_visible = false;
  schedule_tile_redraw(true);
  CHECK(s_dirty_count == 0 && s_tile_redraw_deferred,
        "tile redraw must defer while an overlay obscures the map");

  s_rendering_visible = true;
  flush_deferred_tile_redraw();
  CHECK(s_dirty_count == 1 && !s_tile_redraw_deferred,
        "closing an overlay must flush exactly one deferred tile redraw");
  flush_deferred_tile_redraw();
  CHECK(s_dirty_count == 1,
        "a consumed deferred redraw must not be emitted twice");
}

static void test_exact_render_requests_lead_prefetch_fringe(void) {
  reset_fixture();
  set_visible_origins(3);
  s_visible_origins[0] = s_request_origins[1];
  s_visible_origin_count = 1;

  queue_visible_tiles();
  CHECK(find_flight_for_coordinate(54, 0, 16) != NULL,
        "exact render coverage must dispatch before request-envelope fringe");
  CHECK(find_flight_for_coordinate(0, 0, 16) == NULL,
        "prefetch order must remain behind exact render coverage");
}

static void test_prefetch_suppression_recovers_when_exact(void) {
  reset_fixture();
  set_visible_origins(2);
  s_visible_origins[0] = s_request_origins[1];
  s_visible_origin_count = 1;
  TileRequest scratch[TILE_CACHE_SIZE];
  visible_tile_origins(scratch, TILE_CACHE_SIZE);
  suppress_tile_request(0, 0, 16);

  s_visible_origins[0] = s_request_origins[0];
  queue_visible_tiles();
  CHECK(!tile_request_is_suppressed(0, 0, 16),
        "a suppressed prefetch tile must recover when it enters exact view");
  CHECK(find_flight_for_coordinate(0, 0, 16) != NULL,
        "newly exact recovered coverage must be re-requested immediately");
}

int main(void) {
  test_two_flight_window_and_ack_semantics();
  test_control_message_priority();
  test_outbox_failure_preserves_next_request_correlation();
  test_decode_suppression_covers_the_visible_grid();
  test_unsent_begin_failure_retries_without_external_input();
  test_ready_retry_attempt_survives_queue_rebuild();
  test_touchdown_retires_flights_and_clears_queue();
  test_pause_resume_replaces_flights_and_ignores_late_chunks();
  test_resume_waits_full_grace_period();
  test_interrupting_touchdown_restarts_resume_grace_once();
  test_timeout_retry_isolated_from_other_flight();
  test_discard_timeout_does_not_retry();
  test_tile_error_requires_exact_request_id();
  test_tile_redraw_defers_behind_overlay();
  test_exact_render_requests_lead_prefetch_fringe();
  test_prefetch_suppression_recovers_when_exact();
  cancel_remaining_timers();
  if (s_failures > 0) {
    fprintf(stderr, "tile request scheduler tests: %d failure(s)\n", s_failures);
    return 1;
  }
  puts("tile request scheduler tests: all checks passed");
  return 0;
}
