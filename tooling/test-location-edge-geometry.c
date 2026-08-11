#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>

#include "../apps/pebble-watch/src/c/location_edge_geometry.h"

#define SCREEN_W 200
#define SCREEN_H 228
#define HALO_RADIUS 8
#define PATH_INSET 5
#define PATH_LENGTH (SCREEN_W / 3)

static int path_length(const LocationEdgePath *path) {
  int length = 0;
  for (uint8_t i = 1; i < path->point_count; i++) {
    int dx = path->points[i].x - path->points[i - 1].x;
    int dy = path->points[i].y - path->points[i - 1].y;
    length += (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);
  }
  return length;
}

static void assert_path_on_perimeter(const LocationEdgePath *path,
                                     int width, int height, int inset) {
  int right = width - 1 - inset;
  int bottom = height - 1 - inset;
  assert(path->point_count >= 2);
  for (uint8_t i = 0; i < path->point_count; i++) {
    LocationEdgePoint point = path->points[i];
    assert(point.x >= inset && point.x <= right);
    assert(point.y >= inset && point.y <= bottom);
    assert(point.x == inset || point.x == right ||
           point.y == inset || point.y == bottom);
  }
  for (uint8_t i = 1; i < path->point_count; i++) {
    assert(path->points[i - 1].x == path->points[i].x ||
           path->points[i - 1].y == path->points[i].y);
  }
}

static LocationEdgePath build_expected_path(int x, int y) {
  LocationEdgePath path;
  assert(location_edge_build_path(x, y, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                  PATH_INSET, PATH_LENGTH, &path));
  assert(path_length(&path) == PATH_LENGTH);
  assert_path_on_perimeter(&path, SCREEN_W, SCREEN_H, PATH_INSET);
  return path;
}

static void test_visibility_threshold(void) {
  LocationEdgePath path;
  assert(!location_edge_build_path(100, 100, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                   PATH_INSET, PATH_LENGTH, &path));
  assert(!location_edge_build_path(-8, 100, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                   PATH_INSET, PATH_LENGTH, &path));
  assert(location_edge_build_path(-9, 100, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                  PATH_INSET, PATH_LENGTH, &path));
  assert(!location_edge_build_path(-5, -5, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                   PATH_INSET, PATH_LENGTH, &path));
  assert(location_edge_build_path(-6, -6, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                  PATH_INSET, PATH_LENGTH, &path));
  assert(!location_edge_build_path(207, 100, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                   PATH_INSET, PATH_LENGTH, &path));
  assert(location_edge_build_path(208, 100, SCREEN_W, SCREEN_H, HALO_RADIUS,
                                  PATH_INSET, PATH_LENGTH, &path));
}

static void test_straight_sides(void) {
  LocationEdgePath top = build_expected_path(100, -9);
  assert(top.point_count == 2);
  assert(top.points[0].x == 67 && top.points[0].y == PATH_INSET);
  assert(top.points[1].x == 133 && top.points[1].y == PATH_INSET);

  LocationEdgePath right = build_expected_path(208, 114);
  assert(right.point_count == 2);
  assert(right.points[0].x == SCREEN_W - 1 - PATH_INSET);
  assert(right.points[1].x == SCREEN_W - 1 - PATH_INSET);

  LocationEdgePath bottom = build_expected_path(100, 236);
  assert(bottom.point_count == 2);
  assert(bottom.points[0].y == SCREEN_H - 1 - PATH_INSET);
  assert(bottom.points[1].y == SCREEN_H - 1 - PATH_INSET);

  LocationEdgePath left = build_expected_path(-9, 114);
  assert(left.point_count == 2);
  assert(left.points[0].x == PATH_INSET);
  assert(left.points[1].x == PATH_INSET);
}

static void assert_corner_path(int x, int y, int corner_x, int corner_y) {
  LocationEdgePath path = build_expected_path(x, y);
  assert(path.point_count == 3);
  assert(path.points[1].x == corner_x);
  assert(path.points[1].y == corner_y);
  int first_leg = path_length(&(LocationEdgePath){
      .point_count = 2,
      .points = {path.points[0], path.points[1]},
  });
  int second_leg = path_length(&(LocationEdgePath){
      .point_count = 2,
      .points = {path.points[1], path.points[2]},
  });
  assert(first_leg == PATH_LENGTH / 2);
  assert(second_leg == PATH_LENGTH - PATH_LENGTH / 2);
}

static void test_exact_corners(void) {
  int right = SCREEN_W - 1 - PATH_INSET;
  int bottom = SCREEN_H - 1 - PATH_INSET;
  assert_corner_path(-9, -9, PATH_INSET, PATH_INSET);
  assert_corner_path(208, -9, right, PATH_INSET);
  assert_corner_path(208, 236, right, bottom);
  assert_corner_path(-9, 236, PATH_INSET, bottom);
}

static void test_near_corner_and_continuity(void) {
  LocationEdgePath near = build_expected_path(190, -9);
  int right = SCREEN_W - 1 - PATH_INSET;
  assert(near.point_count == 3);
  assert(near.points[1].x == right && near.points[1].y == PATH_INSET);

  LocationEdgePath previous = build_expected_path(185, -9);
  for (int x = 186; x <= 198; x++) {
    LocationEdgePath current = build_expected_path(x, -9);
    int start_delta = current.points[0].x - previous.points[0].x;
    if (start_delta < 0) {
      start_delta = -start_delta;
    }
    assert(start_delta <= 1);
    previous = current;
  }
}

static void test_runtime_bounds_and_large_coordinates(void) {
  LocationEdgePath path;
  assert(location_edge_build_path(INT32_MIN, 84, 144, 168, HALO_RADIUS,
                                  PATH_INSET, 144 / 3, &path));
  assert(path_length(&path) == 144 / 3);
  assert_path_on_perimeter(&path, 144, 168, PATH_INSET);

  assert(location_edge_build_path(INT32_MAX, INT32_MAX, SCREEN_W, SCREEN_H,
                                  HALO_RADIUS, PATH_INSET, PATH_LENGTH, &path));
  assert(path_length(&path) == PATH_LENGTH);
  assert_path_on_perimeter(&path, SCREEN_W, SCREEN_H, PATH_INSET);
}

int main(void) {
  test_visibility_threshold();
  test_straight_sides();
  test_exact_corners();
  test_near_corner_and_continuity();
  test_runtime_bounds_and_large_coordinates();
  puts("location edge geometry tests: all checks passed");
  return 0;
}
