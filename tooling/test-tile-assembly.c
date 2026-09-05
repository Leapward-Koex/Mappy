// Run the production AppMessage assembly path with a minimal Pebble host surface.
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../apps/pebble-watch/src/c/tile_codec.h"
#include "../apps/pebble-watch/src/c/tile_storage.h"
#define MAPPY_H
#define MIN_MAP_ZOOM 1
#define MAX_MAP_ZOOM 18
#define MAX_TILE_BYTES 6804
#define MAX_TILE_ENCODED_BYTES (108 * 126)
#define APP_LOG(...) ((void)0)
#define tile_performance_clock() 0u
#define tile_performance_begin() ((void)0)
#define tile_performance_decode_end(started) ((void)(started))
#define tile_performance_accepted(...) ((void)0)
enum { TUPLE_BYTE_ARRAY, TUPLE_CSTRING, TUPLE_UINT, TUPLE_INT };
enum { MESSAGE_KEY_width=51, MESSAGE_KEY_height, MESSAGE_KEY_compression_format=55,
       MESSAGE_KEY_total_bytes, MESSAGE_KEY_chunk_index, MESSAGE_KEY_chunk_offset,
       MESSAGE_KEY_chunk_data, MESSAGE_KEY_world_x=63, MESSAGE_KEY_world_y,
       MESSAGE_KEY_tile_zoom, MESSAGE_KEY_request_id=70 };
typedef union { int32_t int32; uint32_t uint32; uint8_t data[MAX_TILE_ENCODED_BYTES]; } TupleValue;
typedef struct { uint32_t key; int type; uint16_t length; TupleValue *value; } Tuple;
typedef struct { Tuple tuples[11]; size_t count; } DictionaryIterator;
typedef struct { int32_t world_x, world_y; int8_t zoom; } TileRequest;
typedef struct { TileRequest request; int32_t request_id; bool active, discard_only; } TileFlight;
typedef struct { int32_t world_x, world_y; int8_t zoom; bool valid, storage_suppressed;
                 uint16_t encoded_length; uint32_t last_used; TileStorageRef storage; } TileCacheEntry;
typedef enum { TileApplyIgnored, TileApplyIncomplete, TileApplyCompletedVisible,
               TileApplyCompletedOffscreen, TileApplyDiscarded, TileApplyRejected } TileApplyResult;
typedef struct { const char *name; uint16_t width, height; uint8_t format;
                 const uint8_t *payload; size_t payload_len;
                 const uint8_t *packed; size_t packed_len; } CodecVector;
#include "tile-codec-vectors.generated.h"
static int s_tile_width, s_tile_height, s_tile_pixels, s_tile_bytes;
static int32_t s_tile_chunk_world_x, s_tile_chunk_world_y, s_tile_chunk_total;
static int32_t s_tile_chunk_received, s_tile_chunk_next_index, s_tile_chunk_request_id;
static int8_t s_tile_chunk_zoom;
static int s_tile_chunk_width, s_tile_chunk_height;
static bool s_tile_chunk_active, s_tile_chunk_store_packed;
static TileStreamDecoder s_tile_chunk_decoder;
static uint32_t s_access_counter;
static uint8_t s_tile_decode_scratch[MAX_TILE_BYTES], s_storage[MAX_TILE_BYTES];
static TileStorageArena s_tile_storage_arena;
static TileFlight s_flight;
static TileCacheEntry s_entry;
static int s_completions;
static bool s_visible;
static Tuple *dict_find(DictionaryIterator *iter, uint32_t key) {
  for (size_t i=0; i<iter->count; i++) if (iter->tuples[i].key==key) return &iter->tuples[i];
  return NULL;
}
static void reset_tile_chunk_assembly(void) {
  s_tile_chunk_active=false; s_tile_chunk_received=0; s_tile_chunk_next_index=0;
}
static TileFlight *find_tile_flight(int32_t x, int32_t y, int8_t z, int32_t id) {
  return s_flight.active && s_flight.request.world_x==x && s_flight.request.world_y==y &&
      s_flight.request.zoom==z && s_flight.request_id==id ? &s_flight : NULL;
}
static void complete_tile_flight(TileFlight *flight) { flight->active=false; s_completions++; }
static void suppress_tile_request(int32_t x, int32_t y, int8_t z) { (void)x; (void)y; (void)z; }
static void set_bottom_text(const char *text) { (void)text; }
static void schedule_tile_redraw(bool immediate) { (void)immediate; }
static void send_log_event(int a, int b, int c, const char *text) { (void)a; (void)b; (void)c; (void)text; }
static bool tile_coordinates_visible(int32_t x, int32_t y, int8_t z) { (void)x; (void)y; (void)z; return s_visible; }
static TileCacheEntry *allocate_tile_slot_with_diagnostics(int32_t x, int32_t y, int8_t z, void *d) {
  (void)x; (void)y; (void)z; (void)d; return &s_entry;
}
static bool reserve_tile_storage(TileCacheEntry *entry, uint16_t size, TileStorageFormat format) {
  return tile_storage_arena_reserve(&s_tile_storage_arena,&entry->storage,size,format);
}
static bool tile_is_visible(const TileCacheEntry *entry) { (void)entry; return s_visible; }
static bool start_tile_animation(TileCacheEntry *entry, bool pending) { (void)entry; (void)pending; return false; }
static int valid_visible_tile_count(void) { return 1; }
static void zoom_fallback_maybe_finish(void) {}
static void update_state_after_map_change(void) {}
static bool visible_grid_is_complete(void) { return true; }
#include "../apps/pebble-watch/src/c/tile_decode.c"
static TupleValue s_values[11];
static DictionaryIterator s_dictionary;
static void reset(const CodecVector *v) {
  memset(&s_entry,0,sizeof(s_entry)); tile_storage_ref_reset(&s_entry.storage);
  tile_storage_arena_init(&s_tile_storage_arena,s_storage,sizeof(s_storage));
  reset_tile_chunk_assembly(); s_completions=0; s_visible=true;
  s_flight=(TileFlight){{54,63,16},123,true,false};
  s_tile_width=v->width; s_tile_height=v->height;
  s_tile_pixels=v->width*v->height; s_tile_bytes=s_tile_pixels/2;
}
static DictionaryIterator *chunk(const CodecVector *v, size_t offset, size_t length, int index) {
  const int keys[]={MESSAGE_KEY_world_x,MESSAGE_KEY_world_y,MESSAGE_KEY_tile_zoom,
    MESSAGE_KEY_width,MESSAGE_KEY_height,MESSAGE_KEY_total_bytes,MESSAGE_KEY_compression_format,
    MESSAGE_KEY_chunk_index,MESSAGE_KEY_chunk_offset,MESSAGE_KEY_request_id,MESSAGE_KEY_chunk_data};
  const int32_t values[]={54,63,16,v->width,v->height,(int32_t)v->payload_len,v->format,index,(int32_t)offset,123,0};
  s_dictionary.count=11;
  for (size_t i=0;i<11;i++) {
    s_values[i].int32=values[i];
    s_dictionary.tuples[i]=(Tuple){keys[i],TUPLE_INT,4,&s_values[i]};
  }
  s_dictionary.tuples[10].type=TUPLE_BYTE_ARRAY;
  s_dictionary.tuples[10].length=length;
  memcpy(s_values[10].data,v->payload+offset,length);
  return &s_dictionary;
}
static void check_rejected(void) {
  assert(apply_tile(&s_dictionary)==TileApplyRejected);
  assert(!s_tile_chunk_active && !s_entry.valid && s_completions==1);
}
static void check_vectors(void) {
  const size_t sizes[]={1,7,255,512};
  for (size_t v=0;v<sizeof(s_vectors)/sizeof(*s_vectors);v++) {
    const CodecVector *vector=&s_vectors[v];
    for (size_t n=0;n<sizeof(sizes)/sizeof(*sizes);n++) {
      reset(vector); int index=0;
      for (size_t offset=0;offset<vector->payload_len;offset+=sizes[n]) {
        size_t count=vector->payload_len-offset;
        if (count>sizes[n]) count=sizes[n];
        TileApplyResult expected=offset+count==vector->payload_len ? TileApplyCompletedVisible : TileApplyIncomplete;
        assert(apply_tile(chunk(vector,offset,count,index++))==expected);
      }
      assert(s_entry.valid && s_completions==1 && !s_tile_chunk_active);
      assert(s_entry.storage.length<=s_tile_bytes);
      uint8_t row[54];
      for (int y=0;y<s_tile_height;y++) {
        assert(decode_cached_tile_row(&s_entry,y,row,sizeof(row)));
        assert(memcmp(row,vector->packed+y*s_tile_width/2,s_tile_width/2)==0);
      }
    }
  }
}
static void check_metadata(void) {
  const CodecVector *v=&s_vectors[0]; assert(v->payload_len>2);
  // All eleven fields are mandatory, with exact integer size and payload type.
  for (size_t field=0;field<11;field++) for(int malformed=0;malformed<3;malformed++) {
    reset(v); assert(apply_tile(chunk(v,0,1,0))==TileApplyIncomplete);
    chunk(v,1,1,1);
    if (malformed==0) s_dictionary.tuples[field].key=999;
    else if (malformed==1) s_dictionary.tuples[field].type=TUPLE_CSTRING;
    else if (field<10) s_dictionary.tuples[field].length=1;
    else s_dictionary.tuples[field].length=0;
    // An invalid/missing request ID cannot be associated safely with a flight.
    if(field==9) { assert(apply_tile(&s_dictionary)==TileApplyIgnored); continue; }
    check_rejected();
  }
  // An initial chunk with missing metadata also completes its identified flight.
  for(size_t field=3;field<=8;field++) {
    reset(v); chunk(v,0,1,0); s_dictionary.tuples[field].key=999; check_rejected();
  }
  // Same ID must keep all identity fields, geometry, total bytes and codec.
  for(size_t field=0;field<=6;field++) {
    reset(v); assert(apply_tile(chunk(v,0,1,0))==TileApplyIncomplete);
    chunk(v,0,1,0); s_values[field].int32++; check_rejected();
  }
  for(size_t field=7;field<=8;field++) {
    reset(v); assert(apply_tile(chunk(v,0,1,0))==TileApplyIncomplete);
    chunk(v,1,1,1); s_values[field].int32++; check_rejected();
  }
  reset(v); assert(apply_tile(chunk(v,0,1,0))==TileApplyIncomplete);
  chunk(v,0,1,0); check_rejected(); // Duplicate chunk cannot restart assembly.
  reset(v); assert(apply_tile(chunk(v,0,1,0))==TileApplyIncomplete);
  chunk(v,1,1,1); s_values[2].int32=272; check_rejected(); // No int8 zoom wrap.
  reset(v); assert(apply_tile(chunk(v,0,1,0))==TileApplyIncomplete);
  chunk(v,1,1,1); s_values[6].int32=5; check_rejected();
  reset(v); chunk(v,0,1,0); s_values[9].int32=999;
  assert(apply_tile(&s_dictionary)==TileApplyIgnored && s_completions==0);
  // Discarded work drains without allocation and a completed stale ID is ignored.
  reset(v); s_visible=false;
  assert(apply_tile(chunk(v,0,v->payload_len,0))==TileApplyDiscarded);
  assert(!s_entry.valid && s_completions==1);
  assert(apply_tile(&s_dictionary)==TileApplyIgnored);
}
int main(void) {
  check_vectors(); check_metadata();
  puts("tile assembly: 12 golden vectors at 4 chunk sizes, metadata/type/order/stale checks passed");
  return 0;
}
