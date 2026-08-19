#include <stdio.h>
#include <string.h>

#include "tile-animation-host-shim.h"

static TileCacheEntry s_entries[TILE_CACHE_SIZE];
static AppTimer s_timer;
static uint64_t s_now_ms;
static bool s_rendering_visible;
static bool s_allow_timer;
static bool s_pan_inertia_active;
static bool s_zoom_fallback_active;
static int s_schedule_count;
static int s_release_count;
static int s_failures;

TileCacheEntry *s_tiles = s_entries;
AppTimer *s_visual_animation_timer;
int8_t s_viewport_zoom;
int s_tile_animation_mode;
bool s_touch_active;

#define CHECK(condition, message) do { \
  if (!(condition)) { \
    fprintf(stderr, "FAIL: %s\n", message); \
    s_failures++; \
  } \
} while (0)

void time_ms(time_t *seconds, uint16_t *milliseconds) {
  *seconds = (time_t)(s_now_ms / 1000);
  *milliseconds = (uint16_t)(s_now_ms % 1000);
}

int active_tile_cache_size(void) {
  return TILE_CACHE_SIZE;
}

bool map_orientation_active(void) {
  return false;
}

int visible_tile_origins(TileRequest *origins, int max_count) {
  (void)origins;
  (void)max_count;
  return 0;
}

bool tile_origin_list_contains(const TileRequest *origins, int count,
                               int32_t world_x, int32_t world_y, int8_t zoom) {
  (void)origins;
  (void)count;
  (void)world_x;
  (void)world_y;
  (void)zoom;
  return false;
}

bool tile_is_visible(const TileCacheEntry *entry) {
  return entry && entry->valid && entry->world_x != 999;
}

bool map_bearing_rendering_visible(void) {
  return s_rendering_visible;
}

bool pan_inertia_animation_active(void) {
  return s_pan_inertia_active;
}

bool zoom_fallback_active(void) {
  return s_zoom_fallback_active;
}

int normalize_tile_animation_mode(int mode) {
  if (mode < TILE_ANIMATION_NONE || mode > TILE_ANIMATION_FADE_ZOOM) {
    return TILE_ANIMATION_FADE_ZOOM;
  }
  return mode;
}

void schedule_visual_animation_tick(void) {
  s_schedule_count++;
  s_visual_animation_timer = s_allow_timer ? &s_timer : NULL;
}

void release_visual_animation_tick_if_idle(void) {
  s_release_count++;
  if (!any_tile_animation_active()) {
    s_visual_animation_timer = NULL;
  }
}

static void reset_fixture(void) {
  memset(s_entries, 0, sizeof(s_entries));
  for (int i = 0; i < TILE_CACHE_SIZE; i++) {
    s_entries[i].valid = true;
    s_entries[i].world_x = i * 54;
    s_entries[i].zoom = 16;
  }
  s_now_ms = 100000;
  s_viewport_zoom = 16;
  s_tile_animation_mode = TILE_ANIMATION_FADE_ZOOM;
  s_touch_active = false;
  s_rendering_visible = true;
  s_allow_timer = true;
  s_pan_inertia_active = false;
  s_zoom_fallback_active = false;
  s_schedule_count = 0;
  s_release_count = 0;
  s_visual_animation_timer = NULL;
}

static void start_at(TileCacheEntry *entry, uint8_t mode,
                     uint32_t elapsed_ms) {
  entry->animation_active = true;
  entry->animation_mode = mode;
  uint64_t started_ms = s_now_ms - elapsed_ms;
  entry->animation_started_s = (time_t)(started_ms / 1000);
  entry->animation_started_ms = (uint16_t)(started_ms % 1000);
}

static void test_duration_progress_and_easing(void) {
  reset_fixture();
  TileCacheEntry *entry = &s_entries[0];

  CHECK(tile_animation_duration_ms(TILE_ANIMATION_FADE) == 180,
        "fade should use the 180ms interaction budget");
  CHECK(tile_animation_duration_ms(TILE_ANIMATION_FADE_ZOOM) == 220,
        "fade + zoom should use the 220ms interaction budget");

  start_at(entry, TILE_ANIMATION_FADE, 90);
  CHECK(tile_animation_elapsed_ms(entry) == 90,
        "elapsed time should span second boundaries exactly");
  CHECK(tile_animation_progress_q8(entry) == 128,
        "fade should reach half Q8 progress at 90ms");
  CHECK(tile_animation_eased_q8(0) == 0,
        "cubic ease-out should preserve the initial phase");
  CHECK(tile_animation_eased_q8(64) == 148,
        "cubic ease-out should reveal pixels quickly in the first quarter");
  CHECK(tile_animation_eased_q8(128) == 224,
        "cubic ease-out should reach 7/8 visibility at half time");
  CHECK(tile_animation_eased_q8(192) == 252,
        "cubic ease-out should settle smoothly in the final quarter");
  CHECK(tile_animation_eased_q8(256) == 256,
        "cubic ease-out should preserve the completed phase");

  uint16_t previous = 0;
  for (uint16_t progress = 0; progress <= 256; progress++) {
    uint16_t eased = tile_animation_eased_q8(progress);
    CHECK(eased >= previous && eased <= 256,
          "cubic ease-out must be monotonic and bounded");
    previous = eased;
  }

  start_at(entry, TILE_ANIMATION_FADE_ZOOM, 219);
  CHECK(tile_animation_progress_q8(entry) < 256,
        "fade + zoom should remain active before its deadline");
  start_at(entry, TILE_ANIMATION_FADE_ZOOM, 220);
  CHECK(tile_animation_progress_q8(entry) == 256,
        "fade + zoom should finish exactly at its deadline");
}

static void test_completion_and_visibility(void) {
  reset_fixture();
  TileCacheEntry *entry = &s_entries[0];
  start_at(entry, TILE_ANIMATION_FADE, TILE_ANIMATION_FADE_MS);

  CHECK(advance_tile_animations(),
        "the deadline tick should request the final visible frame");
  CHECK(!entry->animation_active && entry->animation_mode == TILE_ANIMATION_NONE,
        "the deadline tick should retire animation before the final redraw");
  CHECK(!advance_tile_animations(),
        "completion should require no sentinel wake or extra redraw");

  reset_fixture();
  entry = &s_entries[0];
  entry->world_x = 999;
  start_at(entry, TILE_ANIMATION_FADE, 1);
  CHECK(!advance_tile_animations(),
        "an offscreen animation should not dirty the visible map");
  CHECK(!entry->animation_active,
        "an offscreen animation should be completed immediately");

  reset_fixture();
  start_at(&s_entries[0], TILE_ANIMATION_FADE, 1);
  start_at(&s_entries[1], TILE_ANIMATION_FADE_ZOOM, 1);
  complete_tile_animations();
  CHECK(!any_tile_animation_active(),
        "bulk completion should retire every active tile");
  CHECK(s_release_count == 1 && s_visual_animation_timer == NULL,
        "bulk completion should release an otherwise idle visual timer");
}

static void test_start_guards_and_timer_failure(void) {
  reset_fixture();
  TileCacheEntry *entry = &s_entries[0];
  CHECK(start_tile_animation(entry, true),
        "a pending visible tile should begin its configured animation");
  CHECK(entry->animation_active &&
            entry->animation_mode == TILE_ANIMATION_FADE_ZOOM &&
            entry->animation_started_s == 100 &&
            entry->animation_started_ms == 0,
        "a successful start should record mode and one frame timestamp");
  CHECK(s_schedule_count == 1 && s_visual_animation_timer != NULL,
        "a successful start should schedule the shared visual timer");

  reset_fixture();
  CHECK(!start_tile_animation(entry, false) && s_schedule_count == 0,
        "a cache hit should not animate as a newly pending tile");

  reset_fixture();
  s_touch_active = true;
  CHECK(!start_tile_animation(entry, true) && s_schedule_count == 0,
        "touch interaction should suppress new tile animation work");

  reset_fixture();
  s_allow_timer = false;
  CHECK(!start_tile_animation(entry, true),
        "a timer registration failure should reject the animation start");
  CHECK(!entry->animation_active && entry->animation_mode == TILE_ANIMATION_NONE,
        "timer failure should leave the tile immediately renderable");
}

static void test_burst_degradation_and_bound(void) {
  reset_fixture();
  start_at(&s_entries[0], TILE_ANIMATION_FADE_ZOOM, 30);
  CHECK(start_tile_animation(&s_entries[1], true),
        "a second pending tile should join an active reveal burst");
  CHECK(s_entries[1].animation_mode == TILE_ANIMATION_FADE,
        "a concurrent fade + zoom should degrade to a cheaper fade");
  CHECK(s_entries[1].animation_started_s == s_entries[0].animation_started_s &&
            s_entries[1].animation_started_ms ==
                s_entries[0].animation_started_ms,
        "staggered arrivals should inherit the burst deadline");
  CHECK(!start_tile_animation(&s_entries[2], true),
        "the active animation count should remain strictly bounded");

  reset_fixture();
  s_zoom_fallback_active = true;
  CHECK(start_tile_animation(&s_entries[0], true),
        "zoom fallback should preserve the configured tile reveal");
  CHECK(s_entries[0].animation_mode == TILE_ANIMATION_FADE_ZOOM,
        "the first zoom-fallback tile should keep fade + zoom");
  CHECK(start_tile_animation(&s_entries[1], true),
        "a second zoom-fallback tile should join the bounded burst");
  CHECK(s_entries[1].animation_mode == TILE_ANIMATION_FADE,
        "the second zoom-fallback tile should degrade to fade");
  CHECK(!start_tile_animation(&s_entries[2], true),
        "zoom fallback should retain the two-animation burst cap");

  reset_fixture();
  s_pan_inertia_active = true;
  CHECK(!start_tile_animation(&s_entries[0], true) && s_schedule_count == 0,
        "coast interaction should suppress decorative tile work");
}

int main(void) {
  test_duration_progress_and_easing();
  test_completion_and_visibility();
  test_start_guards_and_timer_failure();
  test_burst_degradation_and_bound();
  if (s_failures > 0) {
    fprintf(stderr, "tile animation tests: %d failure(s)\n", s_failures);
    return 1;
  }
  puts("tile animation tests: all checks passed");
  return 0;
}
