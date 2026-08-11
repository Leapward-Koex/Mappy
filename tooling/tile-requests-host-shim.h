#ifndef MAPPY_TILE_REQUESTS_HOST_SHIM_H
#define MAPPY_TILE_REQUESTS_HOST_SHIM_H

#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TILE_CACHE_SIZE 42
#define TILE_REQUEST_STALE_MS 8000
#define TILE_REQUEST_WATCHDOG_MS 1000
#define TILE_REQUEST_MAX_FLIGHTS 2
#define TILE_REQUEST_TOUCH_RESUME_MS 100
#define TILE_REDRAW_COALESCE_MS 60

#define CMD_TILE_REQUEST 202
#define MESSAGE_KEY_world_x 63
#define MESSAGE_KEY_world_y 64
#define MESSAGE_KEY_tile_zoom 65
#define MESSAGE_KEY_is_color 54
#define MESSAGE_KEY_request_id 70

#define APP_MSG_OK 0
#define APP_LOG_LEVEL_WARNING 1
#define APP_LOG(level, format, ...) ((void)0)

typedef int AppMessageResult;
typedef struct DictionaryIterator {
  int unused;
} DictionaryIterator;
typedef struct Layer {
  int unused;
} Layer;
typedef struct AppTimer AppTimer;
typedef void (*AppTimerCallback)(void *context);

typedef struct {
  int16_t w;
  int16_t h;
} GSize;

typedef struct {
  GSize size;
} GRect;

typedef struct {
  int32_t world_x;
  int32_t world_y;
  int8_t zoom;
} TileRequest;

typedef struct {
  TileRequest request;
  int32_t request_id;
  time_t started_s;
  uint16_t started_ms;
  uint8_t retry_attempt;
  bool active;
  bool discard_only;
} TileFlight;

typedef struct {
  int32_t world_x;
  int32_t world_y;
  int8_t zoom;
  bool valid;
  bool storage_suppressed;
} TileCacheEntry;

extern TileRequest s_request_queue[TILE_CACHE_SIZE];
extern uint8_t s_request_retry_attempts[TILE_CACHE_SIZE];
extern int s_request_count;
extern int s_request_index;
extern int32_t s_inflight_tile_request_id;
extern TileFlight s_tile_flights[TILE_REQUEST_MAX_FLIGHTS];
extern bool s_tile_requests_interaction_paused;
extern bool s_tile_requests_setup_paused;
extern AppTimer *s_tile_request_resume_timer;
extern AppTimer *s_tile_redraw_timer;
extern AppTimer *s_tile_request_watchdog_timer;
extern bool s_outbox_busy;
extern int32_t s_outbox_cmd;
extern int32_t s_next_request_id;
extern int s_theme_mode;
extern bool s_has_gps;
extern GRect s_screen_bounds;
extern Layer *s_map_layer;
extern TileCacheEntry *s_tiles;
extern bool s_tile_chunk_active;
extern int32_t s_tile_chunk_request_id;

AppTimer *app_timer_register(uint32_t timeout_ms, AppTimerCallback callback,
                             void *context);
void app_timer_cancel(AppTimer *timer);
void time_ms(time_t *seconds, uint16_t *milliseconds);
void layer_mark_dirty(Layer *layer);

int active_tile_cache_size(void);
TileCacheEntry *find_tile(int32_t world_x, int32_t world_y, int8_t zoom);
bool tile_is_visible(const TileCacheEntry *entry);
bool tile_coordinates_visible(int32_t world_x, int32_t world_y, int8_t zoom);
int visible_tile_origins(TileRequest *origins, int max_count);
bool map_orientation_active(void);
void remember_orientation_tile_origins(const TileRequest *origins, int count);
void invalidate_orientation_tile_coverage(void);
bool visible_grid_has_missing_tiles(void);
void reset_tile_chunk_assembly(void);
void queue_log_event(int category, int detail, int detail2, const char *text);
bool send_deferred_route_action(void);
AppMessageResult send_message_begin(DictionaryIterator **iter, int32_t cmd);
void write_i32(DictionaryIterator *iter, uint32_t key, int32_t value);
AppMessageResult app_message_outbox_send(void);

int active_tile_flight_count(void);
bool any_pending_tile_requests(void);
TileFlight *find_tile_flight(int32_t world_x, int32_t world_y, int8_t zoom,
                            int32_t request_id);
void complete_tile_flight(TileFlight *flight);
void retry_tile_flight(TileFlight *flight, bool retry_immediately);
void handle_tile_request_error(int32_t world_x, int32_t world_y, int8_t zoom,
                               int32_t request_id, bool setup_required,
                               bool retry_immediately);
void handle_tile_request_outbox_failure(AppMessageResult reason);
bool expire_stale_tile_requests(void);
void tile_request_watchdog_callback(void *data);
void schedule_tile_request_watchdog(void);
void cancel_tile_request_watchdog(void);
void clear_unsent_tile_requests(void);
void clear_offscreen_pending_tile_requests(void);
bool tile_request_is_suppressed(int32_t world_x, int32_t world_y, int8_t zoom);
void suppress_tile_request(int32_t world_x, int32_t world_y, int8_t zoom);
void cancel_all_tile_requests(void);
void cancel_tile_redraw(void);
void schedule_tile_redraw(bool immediate);
void pause_tile_requests_for_interaction(void);
void resume_tile_requests_after_interaction(void);
void resume_tile_requests_after_phone_ready(void);
bool tile_requests_paused(void);
void queue_visible_tiles(void);
void send_next_tile_request(void);

#endif
