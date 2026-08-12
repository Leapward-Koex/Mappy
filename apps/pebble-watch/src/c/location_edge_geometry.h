#ifndef MAPPY_LOCATION_EDGE_GEOMETRY_H
#define MAPPY_LOCATION_EDGE_GEOMETRY_H

#include <stdbool.h>
#include <stdint.h>

#define LOCATION_EDGE_MAX_PATH_POINTS 6

typedef struct {
  int16_t x;
  int16_t y;
} LocationEdgePoint;

typedef struct {
  uint8_t point_count;
  LocationEdgePoint points[LOCATION_EDGE_MAX_PATH_POINTS];
} LocationEdgePath;

bool location_edge_build_path(int32_t projected_x, int32_t projected_y,
                              int16_t screen_width, int16_t screen_height,
                              int16_t visible_radius, int16_t perimeter_inset,
                              int16_t line_length, LocationEdgePath *path_out);

#endif
