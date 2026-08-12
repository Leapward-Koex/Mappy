#include "location_edge_geometry.h"

#include <stddef.h>

static int32_t clamp_i32(int32_t value, int32_t minimum, int32_t maximum) {
  if (value < minimum) {
    return minimum;
  }
  if (value > maximum) {
    return maximum;
  }
  return value;
}

static int64_t abs_i64(int64_t value) {
  return value < 0 ? -value : value;
}

static bool visible_circle_intersects_screen(int32_t point_x, int32_t point_y,
                                             int16_t screen_width,
                                             int16_t screen_height,
                                             int16_t radius) {
  int32_t nearest_x = clamp_i32(point_x, 0, screen_width - 1);
  int32_t nearest_y = clamp_i32(point_y, 0, screen_height - 1);
  int64_t dx = (int64_t)point_x - nearest_x;
  int64_t dy = (int64_t)point_y - nearest_y;
  int64_t radius_i64 = radius;

  if (abs_i64(dx) > radius_i64 || abs_i64(dy) > radius_i64) {
    return false;
  }
  return dx * dx + dy * dy <= radius_i64 * radius_i64;
}

static int32_t normalize_perimeter_offset(int32_t offset,
                                          int32_t perimeter_length) {
  int32_t normalized = offset % perimeter_length;
  if (normalized < 0) {
    normalized += perimeter_length;
  }
  return normalized;
}

static LocationEdgePoint perimeter_point(int32_t offset, int16_t left,
                                         int16_t top, int16_t right,
                                         int16_t bottom) {
  int32_t horizontal = right - left;
  int32_t vertical = bottom - top;
  int32_t perimeter = 2 * (horizontal + vertical);
  int32_t normalized = normalize_perimeter_offset(offset, perimeter);

  if (normalized < horizontal) {
    return (LocationEdgePoint){(int16_t)(left + normalized), top};
  }
  normalized -= horizontal;
  if (normalized < vertical) {
    return (LocationEdgePoint){right, (int16_t)(top + normalized)};
  }
  normalized -= vertical;
  if (normalized < horizontal) {
    return (LocationEdgePoint){(int16_t)(right - normalized), bottom};
  }
  normalized -= horizontal;
  return (LocationEdgePoint){left, (int16_t)(bottom - normalized)};
}

static int32_t distance_to_next_corner(int32_t offset, int32_t horizontal,
                                       int32_t vertical) {
  int32_t perimeter = 2 * (horizontal + vertical);
  int32_t normalized = normalize_perimeter_offset(offset, perimeter);
  int32_t top_right = horizontal;
  int32_t bottom_right = horizontal + vertical;
  int32_t bottom_left = horizontal * 2 + vertical;

  if (normalized < top_right) {
    return top_right - normalized;
  }
  if (normalized < bottom_right) {
    return bottom_right - normalized;
  }
  if (normalized < bottom_left) {
    return bottom_left - normalized;
  }
  return perimeter - normalized;
}

static bool append_path_point(LocationEdgePath *path, LocationEdgePoint point) {
  if (path->point_count >= LOCATION_EDGE_MAX_PATH_POINTS) {
    return false;
  }
  if (path->point_count > 0) {
    LocationEdgePoint previous = path->points[path->point_count - 1];
    if (previous.x == point.x && previous.y == point.y) {
      return true;
    }
  }
  path->points[path->point_count++] = point;
  return true;
}

static int32_t clamped_anchor_offset(int32_t point_x, int32_t point_y,
                                     int16_t screen_width,
                                     int16_t screen_height, int16_t left,
                                     int16_t top, int16_t right,
                                     int16_t bottom) {
  int32_t horizontal = right - left;
  int32_t vertical = bottom - top;

  if (point_y < 0) {
    return clamp_i32(point_x, left, right) - left;
  }
  if (point_x >= screen_width) {
    return horizontal + clamp_i32(point_y, top, bottom) - top;
  }
  if (point_y >= screen_height) {
    return horizontal + vertical + right -
        clamp_i32(point_x, left, right);
  }
  return horizontal * 2 + vertical + bottom -
      clamp_i32(point_y, top, bottom);
}

bool location_edge_build_path(int32_t projected_x, int32_t projected_y,
                              int16_t screen_width, int16_t screen_height,
                              int16_t visible_radius, int16_t perimeter_inset,
                              int16_t line_length, LocationEdgePath *path_out) {
  if (!path_out) {
    return false;
  }
  path_out->point_count = 0;
  if (screen_width <= 1 || screen_height <= 1 || visible_radius < 0 ||
      perimeter_inset < 0 || line_length <= 0) {
    return false;
  }
  if (visible_circle_intersects_screen(projected_x, projected_y, screen_width,
                                       screen_height, visible_radius)) {
    return false;
  }

  int16_t left = perimeter_inset;
  int16_t top = perimeter_inset;
  int16_t right = screen_width - 1 - perimeter_inset;
  int16_t bottom = screen_height - 1 - perimeter_inset;
  if (left >= right || top >= bottom) {
    return false;
  }

  int32_t horizontal = right - left;
  int32_t vertical = bottom - top;
  int32_t perimeter = 2 * (horizontal + vertical);
  int32_t bounded_length = line_length > perimeter ? perimeter : line_length;
  int32_t anchor = clamped_anchor_offset(
      projected_x, projected_y, screen_width, screen_height,
      left, top, right, bottom);
  int32_t current = anchor - bounded_length / 2;
  int32_t remaining = bounded_length;

  if (!append_path_point(path_out,
                         perimeter_point(current, left, top, right, bottom))) {
    path_out->point_count = 0;
    return false;
  }

  while (remaining > 0) {
    int32_t to_corner = distance_to_next_corner(current, horizontal, vertical);
    int32_t step = remaining < to_corner ? remaining : to_corner;
    if (step <= 0) {
      path_out->point_count = 0;
      return false;
    }
    current += step;
    remaining -= step;
    if (!append_path_point(path_out,
                           perimeter_point(current, left, top, right, bottom))) {
      path_out->point_count = 0;
      return false;
    }
  }

  return path_out->point_count >= 2;
}
