#include "mappy.h"

// Visible tile queueing and response-bound AppMessage tile request dispatch.

typedef struct {
  TileRequest request;
  AppTimer *timer;
  uint8_t retry_attempt;
  bool active;
} TileRetry;

static TileRetry s_tile_retries[TILE_REQUEST_MAX_FLIGHTS];
static TileRequest s_suppressed_requests[TILE_CACHE_SIZE];
static bool s_suppressed_request_active[TILE_CACHE_SIZE];

static bool request_matches(const TileRequest *request, int32_t world_x,
                            int32_t world_y, int8_t zoom);

bool recover_newly_exact_tile_suppression(
    const TileCoverageEnvelope *previous_render_envelope) {
  bool recovered = false;
  for (int i = 0; i < TILE_CACHE_SIZE; i++) {
    if (!s_suppressed_request_active[i]) {
      continue;
    }
    TileRequest *request = &s_suppressed_requests[i];
    bool was_exact = tile_coverage_envelope_contains(
        previous_render_envelope, request->world_x, request->world_y,
        request->zoom);
    if (!was_exact && tile_coordinates_render_visible(
                          request->world_x, request->world_y, request->zoom)) {
      s_suppressed_request_active[i] = false;
      recovered = true;
      TileCacheEntry *entry = find_tile(request->world_x, request->world_y,
                                        request->zoom);
      if (entry && entry->storage_suppressed) {
        entry->storage_suppressed = false;
      }
    }
  }

  if (!s_tiles) {
    return recovered;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    TileCacheEntry *entry = &s_tiles[i];
    if (!entry->storage_suppressed) {
      continue;
    }
    bool was_exact = tile_coverage_envelope_contains(
        previous_render_envelope, entry->world_x, entry->world_y, entry->zoom);
    if (!was_exact && tile_is_visible(entry)) {
      entry->storage_suppressed = false;
      recovered = true;
    }
  }
  return recovered;
}

static bool request_matches(const TileRequest *request, int32_t world_x,
                            int32_t world_y, int8_t zoom) {
  return request && request->world_x == world_x &&
      request->world_y == world_y && request->zoom == zoom;
}

int active_tile_flight_count(void) {
  int count = 0;
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_flights[i].active) {
      count++;
    }
  }
  return count;
}

static TileFlight *free_tile_flight(void) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (!s_tile_flights[i].active) {
      return &s_tile_flights[i];
    }
  }
  return NULL;
}

static bool coordinate_has_current_flight(int32_t world_x, int32_t world_y,
                                          int8_t zoom) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    TileFlight *flight = &s_tile_flights[i];
    if (flight->active && !flight->discard_only &&
        request_matches(&flight->request, world_x, world_y, zoom)) {
      return true;
    }
  }
  return false;
}

static bool coordinate_waiting_for_retry(int32_t world_x, int32_t world_y,
                                         int8_t zoom) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_retries[i].active && s_tile_retries[i].timer &&
        request_matches(&s_tile_retries[i].request, world_x, world_y, zoom)) {
      return true;
    }
  }
  return false;
}

static bool coordinate_has_retry_record(int32_t world_x, int32_t world_y,
                                        int8_t zoom) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_retries[i].active &&
        request_matches(&s_tile_retries[i].request, world_x, world_y, zoom)) {
      return true;
    }
  }
  return false;
}

static int active_retry_record_count(void) {
  int count = 0;
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_retries[i].active) {
      count++;
    }
  }
  return count;
}

static TileRetry *ready_retry_for_request(const TileRequest *request) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    TileRetry *retry = &s_tile_retries[i];
    if (retry->active && !retry->timer &&
        request_matches(&retry->request, request->world_x,
                        request->world_y, request->zoom)) {
      return retry;
    }
  }
  return NULL;
}

bool tile_request_is_suppressed(int32_t world_x, int32_t world_y, int8_t zoom) {
  for (int i = 0; i < TILE_CACHE_SIZE; i++) {
    if (s_suppressed_request_active[i] &&
        request_matches(&s_suppressed_requests[i], world_x, world_y, zoom)) {
      return true;
    }
  }
  return false;
}

void suppress_tile_request(int32_t world_x, int32_t world_y, int8_t zoom) {
  int slot = -1;
  for (int i = 0; i < TILE_CACHE_SIZE; i++) {
    if (s_suppressed_request_active[i] &&
        request_matches(&s_suppressed_requests[i], world_x, world_y, zoom)) {
      return;
    }
    if (slot < 0 && !s_suppressed_request_active[i]) {
      slot = i;
    }
  }
  if (slot < 0) {
    slot = 0;
  }
  s_suppressed_requests[slot] = (TileRequest) {
    .world_x = world_x,
    .world_y = world_y,
    .zoom = zoom,
  };
  s_suppressed_request_active[slot] = true;
}

bool tile_requests_paused(void) {
  return s_tile_requests_interaction_paused || s_tile_requests_setup_paused;
}

TileFlight *find_tile_flight(int32_t world_x, int32_t world_y, int8_t zoom,
                             int32_t request_id) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    TileFlight *flight = &s_tile_flights[i];
    if (!flight->active ||
        !request_matches(&flight->request, world_x, world_y, zoom)) {
      continue;
    }
    if (flight->request_id == request_id) {
      return flight;
    }
  }
  return NULL;
}

static uint16_t tile_flight_elapsed_ms(const TileFlight *flight) {
  if (!flight || !flight->active) {
    return 0;
  }
  time_t now_s;
  uint16_t now_ms;
  time_ms(&now_s, &now_ms);
  int32_t elapsed = (int32_t)(now_s - flight->started_s) * 1000 +
      (int32_t)now_ms - (int32_t)flight->started_ms;
  if (elapsed <= 0) {
    return 0;
  }
  return elapsed > UINT16_MAX ? UINT16_MAX : (uint16_t)elapsed;
}

bool any_pending_tile_requests(void) {
  return active_tile_flight_count() > 0;
}

static void retire_tile_flight(TileFlight *flight) {
  if (!flight) {
    return;
  }
  int32_t request_id = flight->request_id;
  memset(flight, 0, sizeof(*flight));
  if (s_inflight_tile_request_id == request_id &&
      s_outbox_cmd != CMD_TILE_REQUEST) {
    s_inflight_tile_request_id = 0;
  }
  if (!any_pending_tile_requests()) {
    cancel_tile_request_watchdog();
  }
}

void complete_tile_flight(TileFlight *flight) {
  retire_tile_flight(flight);
  send_next_tile_request();
}

static int retry_delay_ms(uint8_t attempt, bool retry_immediately) {
  if (retry_immediately) {
    return 250;
  }
  static const uint16_t s_delays[] = {1000, 2000, 4000, 8000};
  int index = attempt < 4 ? attempt : 3;
  return s_delays[index];
}

static void rebuild_visible_tile_queue(void);

static void tile_retry_callback(void *context) {
  TileRetry *retry = context;
  if (!retry || !retry->active) {
    return;
  }
  TileRequest request = retry->request;
  retry->timer = NULL;

  if (!tile_coordinates_visible(request.world_x, request.world_y,
                                request.zoom)) {
    retry->active = false;
    send_next_tile_request();
    return;
  }

  rebuild_visible_tile_queue();
  send_next_tile_request();
}

void retry_tile_flight(TileFlight *flight, bool retry_immediately) {
  if (!flight || !flight->active) {
    return;
  }
  TileRequest request = flight->request;
  uint8_t next_attempt = flight->retry_attempt < UINT8_MAX ?
      flight->retry_attempt + 1 : UINT8_MAX;
  int delay_ms = retry_delay_ms(flight->retry_attempt, retry_immediately);

  TileRetry *slot = NULL;
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_retries[i].active &&
        request_matches(&s_tile_retries[i].request, request.world_x,
                        request.world_y, request.zoom)) {
      slot = &s_tile_retries[i];
      break;
    }
    if (!slot && !s_tile_retries[i].active) {
      slot = &s_tile_retries[i];
    }
  }

  retire_tile_flight(flight);
  if (!slot || !tile_coordinates_visible(request.world_x, request.world_y,
                                         request.zoom)) {
    send_next_tile_request();
    return;
  }

  if (slot->timer) {
    app_timer_cancel(slot->timer);
  }
  slot->request = request;
  slot->retry_attempt = next_attempt;
  slot->active = true;
  slot->timer = app_timer_register((uint32_t)delay_ms, tile_retry_callback,
                                   slot);
  if (!slot->timer) {
    rebuild_visible_tile_queue();
  }
  send_next_tile_request();
}

void handle_tile_request_error(int32_t world_x, int32_t world_y, int8_t zoom,
                               int32_t request_id, bool setup_required,
                               bool retry_immediately) {
  if (request_id <= 0) {
    return;
  }
  TileFlight *flight = find_tile_flight(world_x, world_y, zoom, request_id);
  if (!flight) {
    return;
  }
  if (flight->discard_only) {
    complete_tile_flight(flight);
    return;
  }
  if (setup_required) {
    s_tile_requests_setup_paused = true;
    retire_tile_flight(flight);
    clear_unsent_tile_requests();
    for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
      if (s_tile_flights[i].active) {
        s_tile_flights[i].discard_only = true;
      }
    }
    reset_tile_chunk_assembly();
    return;
  }
  retry_tile_flight(flight, retry_immediately);
}

void handle_tile_request_outbox_failure(AppMessageResult reason) {
  int32_t failed_request_id = s_inflight_tile_request_id;
  // Retiring the failed flight can immediately dispatch another request. Clear
  // the old correlation before that happens so we do not erase the new ID.
  s_inflight_tile_request_id = 0;
  TileFlight *flight = NULL;
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_flights[i].active &&
        s_tile_flights[i].request_id == failed_request_id) {
      flight = &s_tile_flights[i];
      break;
    }
  }
  if (flight) {
    queue_log_event(6, flight->request.zoom, (int)reason,
                    "tile request failed");
    if (flight->discard_only) {
      complete_tile_flight(flight);
    } else {
      retry_tile_flight(flight, true);
    }
  }
}

bool expire_stale_tile_requests(void) {
  bool expired_any = false;
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    TileFlight *flight = &s_tile_flights[i];
    if (!flight->active ||
        tile_flight_elapsed_ms(flight) < TILE_REQUEST_STALE_MS) {
      continue;
    }
    APP_LOG(APP_LOG_LEVEL_WARNING, "Tile flight expired");
    if (flight->discard_only) {
      retire_tile_flight(flight);
    } else {
      retry_tile_flight(flight, false);
    }
    expired_any = true;
  }
  return expired_any;
}

void tile_request_watchdog_callback(void *data) {
  (void)data;
  s_tile_request_watchdog_timer = NULL;
  expire_stale_tile_requests();
  send_next_tile_request();
  schedule_tile_request_watchdog();
}

void schedule_tile_request_watchdog(void) {
  bool unsent_work = s_request_index < s_request_count;
  if (!s_tile_request_watchdog_timer && !tile_requests_paused() &&
      (any_pending_tile_requests() || unsent_work)) {
    s_tile_request_watchdog_timer = app_timer_register(
        TILE_REQUEST_WATCHDOG_MS, tile_request_watchdog_callback, NULL);
  }
}

void cancel_tile_request_watchdog(void) {
  if (s_tile_request_watchdog_timer) {
    app_timer_cancel(s_tile_request_watchdog_timer);
    s_tile_request_watchdog_timer = NULL;
  }
}

void clear_unsent_tile_requests(void) {
  s_request_count = 0;
  s_request_index = 0;
  memset(s_request_retry_attempts, 0, sizeof(s_request_retry_attempts));
}

void clear_offscreen_pending_tile_requests(void) {
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    TileFlight *flight = &s_tile_flights[i];
    if (!flight->active || flight->discard_only ||
        tile_coordinates_visible(flight->request.world_x,
                                 flight->request.world_y,
                                 flight->request.zoom)) {
      continue;
    }
    flight->discard_only = true;
    if (s_tile_chunk_active &&
        s_tile_chunk_request_id == flight->request_id) {
      reset_tile_chunk_assembly();
    }
  }

  for (int i = 0; i < TILE_CACHE_SIZE; i++) {
    if (s_suppressed_request_active[i] &&
        !tile_coordinates_visible(s_suppressed_requests[i].world_x,
                                  s_suppressed_requests[i].world_y,
                                  s_suppressed_requests[i].zoom)) {
      s_suppressed_request_active[i] = false;
    }
  }

  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    TileRetry *retry = &s_tile_retries[i];
    if (!retry->active ||
        tile_coordinates_visible(retry->request.world_x,
                                 retry->request.world_y,
                                 retry->request.zoom)) {
      continue;
    }
    if (retry->timer) {
      app_timer_cancel(retry->timer);
    }
    memset(retry, 0, sizeof(*retry));
  }

  if (!s_tiles) {
    return;
  }
  int capacity = active_tile_cache_size();
  for (int i = 0; i < capacity; i++) {
    if (s_tiles[i].storage_suppressed && !tile_coordinates_visible(
            s_tiles[i].world_x, s_tiles[i].world_y, s_tiles[i].zoom)) {
      s_tiles[i].storage_suppressed = false;
    }
  }
}

void cancel_all_tile_requests(void) {
  cancel_tile_request_watchdog();
  clear_unsent_tile_requests();
  reset_tile_chunk_assembly();
  memset(s_tile_flights, 0, sizeof(s_tile_flights));
  memset(s_suppressed_request_active, 0,
         sizeof(s_suppressed_request_active));
  s_inflight_tile_request_id = 0;
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_retries[i].timer) {
      app_timer_cancel(s_tile_retries[i].timer);
    }
    memset(&s_tile_retries[i], 0, sizeof(s_tile_retries[i]));
  }
}

void cancel_tile_redraw(void) {
  if (s_tile_redraw_timer) {
    app_timer_cancel(s_tile_redraw_timer);
    s_tile_redraw_timer = NULL;
  }
}

static void tile_redraw_callback(void *context) {
  (void)context;
  s_tile_redraw_timer = NULL;
  if (!map_bearing_rendering_visible()) {
    s_tile_redraw_deferred = true;
  } else if (!s_tile_requests_interaction_paused && s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void schedule_tile_redraw(bool immediate) {
  if (!map_bearing_rendering_visible()) {
    cancel_tile_redraw();
    s_tile_redraw_deferred = true;
    return;
  }
  if (s_tile_requests_interaction_paused) {
    cancel_tile_redraw();
    return;
  }
  if (immediate) {
    cancel_tile_redraw();
    if (s_map_layer) {
      layer_mark_dirty(s_map_layer);
    }
    return;
  }
  if (!s_tile_redraw_timer) {
    s_tile_redraw_timer = app_timer_register(TILE_REDRAW_COALESCE_MS,
                                             tile_redraw_callback, NULL);
  }
}

void flush_deferred_tile_redraw(void) {
  if (!s_tile_redraw_deferred || !map_bearing_rendering_visible()) {
    return;
  }
  s_tile_redraw_deferred = false;
  cancel_tile_redraw();
  if (s_map_layer) {
    layer_mark_dirty(s_map_layer);
  }
}

void pause_tile_requests_for_interaction(void) {
  s_tile_requests_interaction_paused = true;
  if (s_tile_request_resume_timer) {
    app_timer_cancel(s_tile_request_resume_timer);
    s_tile_request_resume_timer = NULL;
  }
  cancel_tile_redraw();
  clear_unsent_tile_requests();
  for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS; i++) {
    if (s_tile_flights[i].active) {
      s_tile_flights[i].discard_only = true;
      // A pan makes the response irrelevant immediately. Keeping these
      // flights alive until their terminal chunk (or the stale watchdog)
      // would occupy the entire response window and block the new viewport.
      // Retiring also makes find_tile_flight reject every late chunk by its
      // old request ID; s_next_request_id remains monotonic for replacements.
      retire_tile_flight(&s_tile_flights[i]);
    }
  }
  reset_tile_chunk_assembly();
}

static void tile_request_resume_callback(void *context) {
  (void)context;
  s_tile_request_resume_timer = NULL;
  s_tile_requests_interaction_paused = false;
  queue_visible_tiles();
}

void resume_tile_requests_after_interaction(void) {
  if (s_tile_request_resume_timer) {
    app_timer_cancel(s_tile_request_resume_timer);
  }
  s_tile_request_resume_timer = app_timer_register(
      TILE_REQUEST_TOUCH_RESUME_MS, tile_request_resume_callback, NULL);
  if (!s_tile_request_resume_timer) {
    tile_request_resume_callback(NULL);
  }
}

void resume_tile_requests_after_phone_ready(void) {
  s_tile_requests_setup_paused = false;
  if (!s_tile_requests_interaction_paused) {
    queue_visible_tiles();
  }
}

static void rebuild_visible_tile_queue(void) {
  TileCoverageEnvelope previous_render_envelope = s_render_tile_envelope;
  TileRequest origins[TILE_CACHE_SIZE];
  int origin_count = request_tile_origins(origins, active_tile_cache_size());
  refresh_render_tile_coverage();
  recover_newly_exact_tile_suppression(&previous_render_envelope);
  clear_offscreen_pending_tile_requests();
  clear_unsent_tile_requests();
  if (!s_has_gps || s_screen_bounds.size.w == 0 ||
      s_screen_bounds.size.h == 0) {
    return;
  }

  for (int priority = 0; priority < 2; priority++) {
    // Ready retries retain priority within their visibility class, while exact
    // render coverage always leads bearing-independent prefetch fringe work.
    for (int i = 0; i < TILE_REQUEST_MAX_FLIGHTS &&
         s_request_count < TILE_CACHE_SIZE; i++) {
      TileRetry *retry = &s_tile_retries[i];
      if (!retry->active || retry->timer) {
        continue;
      }
      TileRequest request = retry->request;
      bool exact = tile_coordinates_render_visible(
          request.world_x, request.world_y, request.zoom);
      if ((priority == 0) != exact) {
        continue;
      }
      TileCacheEntry *entry = find_tile(request.world_x, request.world_y,
                                        request.zoom);
      if (!tile_coordinates_visible(request.world_x, request.world_y,
                                    request.zoom) ||
          (entry && (entry->valid || entry->storage_suppressed)) ||
          tile_request_is_suppressed(request.world_x, request.world_y,
                                     request.zoom) ||
          coordinate_has_current_flight(request.world_x, request.world_y,
                                        request.zoom)) {
        continue;
      }
      s_request_queue[s_request_count] = request;
      s_request_retry_attempts[s_request_count] = retry->retry_attempt;
      s_request_count++;
    }

    for (int i = 0; i < origin_count && s_request_count < TILE_CACHE_SIZE; i++) {
      TileRequest origin = origins[i];
      bool exact = tile_coordinates_render_visible(
          origin.world_x, origin.world_y, origin.zoom);
      if ((priority == 0) != exact) {
        continue;
      }
      TileCacheEntry *entry = find_tile(origin.world_x, origin.world_y,
                                        origin.zoom);
      if ((entry && (entry->valid || entry->storage_suppressed)) ||
          tile_request_is_suppressed(origin.world_x, origin.world_y,
                                     origin.zoom) ||
          coordinate_has_current_flight(origin.world_x, origin.world_y,
                                        origin.zoom) ||
          coordinate_has_retry_record(origin.world_x, origin.world_y,
                                      origin.zoom)) {
        continue;
      }
      s_request_queue[s_request_count] = origin;
      s_request_retry_attempts[s_request_count] = 0;
      s_request_count++;
    }
  }
}

void queue_visible_tiles(void) {
  if (s_tile_requests_interaction_paused) {
    return;
  }
  rebuild_visible_tile_queue();
  schedule_tile_request_watchdog();
  send_next_tile_request();
}

static uint8_t take_ready_retry_attempt(const TileRequest *request,
                                        uint8_t fallback_attempt) {
  TileRetry *retry = ready_retry_for_request(request);
  if (retry) {
    if (retry->retry_attempt > fallback_attempt) {
      fallback_attempt = retry->retry_attempt;
    }
    memset(retry, 0, sizeof(*retry));
  }
  return fallback_attempt;
}

void send_next_tile_request(void) {
  if (s_outbox_busy || tile_requests_paused() ||
      active_tile_flight_count() >= TILE_REQUEST_MAX_FLIGHTS) {
    return;
  }
  if (send_deferred_route_action()) {
    return;
  }

  while (s_request_index < s_request_count) {
    int queue_index = s_request_index++;
    TileRequest request = s_request_queue[queue_index];
    TileCacheEntry *entry = find_tile(request.world_x, request.world_y,
                                      request.zoom);
    if ((entry && (entry->valid || entry->storage_suppressed)) ||
        tile_request_is_suppressed(request.world_x, request.world_y,
                                   request.zoom) ||
        coordinate_has_current_flight(request.world_x, request.world_y,
                                      request.zoom) ||
        coordinate_waiting_for_retry(request.world_x, request.world_y,
                                     request.zoom) ||
        !tile_coordinates_visible(request.world_x, request.world_y,
                                  request.zoom)) {
      continue;
    }

    if (!ready_retry_for_request(&request) &&
        active_retry_record_count() + active_tile_flight_count() >=
            TILE_REQUEST_MAX_FLIGHTS) {
      // Reserve retry metadata for every active response. Otherwise broad
      // provider failures can overflow the two backoff records and restart a
      // coordinate at attempt zero.
      s_request_index--;
      return;
    }

    TileFlight *flight = free_tile_flight();
    if (!flight) {
      s_request_index--;
      return;
    }
    DictionaryIterator *iter;
    AppMessageResult result = send_message_begin(&iter, CMD_TILE_REQUEST);
    if (result != APP_MSG_OK) {
      s_request_index--;
      schedule_tile_request_watchdog();
      return;
    }

    int32_t request_id = s_next_request_id++;
    if (request_id <= 0 || s_next_request_id <= 0) {
      request_id = 1;
      s_next_request_id = 2;
    }
    memset(flight, 0, sizeof(*flight));
    flight->request = request;
    flight->request_id = request_id;
    flight->retry_attempt = take_ready_retry_attempt(
        &request, s_request_retry_attempts[queue_index]);
    flight->active = true;
    time_ms(&flight->started_s, &flight->started_ms);
    s_inflight_tile_request_id = request_id;
    write_i32(iter, MESSAGE_KEY_world_x, request.world_x);
    write_i32(iter, MESSAGE_KEY_world_y, request.world_y);
    write_i32(iter, MESSAGE_KEY_tile_zoom, request.zoom);
    write_i32(iter, MESSAGE_KEY_is_color, s_theme_mode);
    write_i32(iter, MESSAGE_KEY_request_id, request_id);
    result = app_message_outbox_send();
    if (result != APP_MSG_OK) {
      s_outbox_busy = false;
      s_outbox_cmd = 0;
      handle_tile_request_outbox_failure(result);
    } else {
      schedule_tile_request_watchdog();
    }
    return;
  }

  if (!any_pending_tile_requests() && visible_grid_has_missing_tiles()) {
    rebuild_visible_tile_queue();
    if (s_request_count > 0) {
      send_next_tile_request();
    }
  }
}
