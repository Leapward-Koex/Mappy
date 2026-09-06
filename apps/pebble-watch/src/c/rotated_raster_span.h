#ifndef MAPPY_ROTATED_RASTER_SPAN_H
#define MAPPY_ROTATED_RASTER_SPAN_H

#include <stdbool.h>
#include <stdint.h>

typedef struct {
  int16_t left;
  int16_t top;
  int16_t right;
  int16_t bottom;
} RotatedRasterCover;

typedef struct {
  int16_t left;
  int16_t right;
} RotatedRasterRowCover;

// A current-zoom raster step is at most one source pixel on either axis.
// Include count advances, not count - 1: the last advance prepares the next
// span's cursor. A successful proof permits local-coordinate-only advances.
static inline bool rotated_raster_span_in_tile(
    int x, int y, int width, int height, int count, int dx, int dy) {
  return (unsigned)x < (unsigned)width && (unsigned)y < (unsigned)height &&
      (unsigned)(x + count * dx) < (unsigned)width &&
      (unsigned)(y + count * dy) < (unsigned)height;
}

// draw_card uses radius four. Keep its whole boundary and corners visible;
// only the strict interior is guaranteed independent of the map underneath.
static inline RotatedRasterCover rotated_raster_card_cover(
    int x, int y, int width, int height) {
  return (RotatedRasterCover) {
    .left = (int16_t)(x + 4), .top = (int16_t)(y + 4),
    .right = (int16_t)(x + width - 4),
    .bottom = (int16_t)(y + height - 4),
  };
}

// The top and bottom status cards occupy separate vertical ranges. Resolve
// those ranges once per scanline, outside the destination block/pixel loops.
static inline RotatedRasterRowCover rotated_raster_row_cover(
    const RotatedRasterCover covers[2], int y) {
  for (int i = 0; i < 2; i++) {
    if (y >= covers[i].top && y < covers[i].bottom) {
      return (RotatedRasterRowCover) {covers[i].left, covers[i].right};
    }
  }
  return (RotatedRasterRowCover) {0, 0};
}

static inline bool rotated_raster_row_span_covered(
    RotatedRasterRowCover cover, int x, int count) {
  return x >= cover.left && x + count <= cover.right;
}

static inline bool rotated_raster_span_covered(
    const RotatedRasterCover covers[2], int x, int y, int count) {
  for (int i = 0; i < 2; i++) {
    if (y >= covers[i].top && y < covers[i].bottom &&
        x >= covers[i].left && x + count <= covers[i].right) {
      return true;
    }
  }
  return false;
}

#endif
