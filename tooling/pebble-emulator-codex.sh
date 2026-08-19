#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_DIR="${PEBBLE_WATCH_DIR:-"$ROOT_DIR/apps/pebble-watch"}"
PLATFORM="${PEBBLE_PLATFORM:-emery}"
OUT_DIR="${PEBBLE_CODEX_OUT:-"$WATCH_DIR/codex-emulator"}"
PBW_PATH="${PEBBLE_PBW:-"$WATCH_DIR/build/pebble-watch.pbw"}"
PHONE_MODE="${MAPPY_WATCH_PHONE_MODE:-${PEBBLE_PHONE_MODE:-phone}}"
CAPTURE_DELAY_SECONDS="${PEBBLE_CAPTURE_DELAY_SECONDS:-0}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  doctor                   Verify CLI, SDK, emulator, and helper dependencies.
  test-tooling             Run deterministic Pebble development-tool tests.
  test-protocol            Check protocol constants across specs and runtimes.
  test-motion-host         Run allocation-free motion and bearing host tests.
  test-navigation-feedback-host
                            Run navigation feedback preset policy host tests.
  test-pan-inertia-host    Run fixed-point kinetic pan host tests.
  test-tile-cache-host     Run bounded tile codec and arena host tests.
  test-tile-scheduler-host Run deterministic two-flight scheduler host tests.
  test-face-forward-render-host
                           Run exact rotated-raster tests and the host benchmark.
  test-face-forward-angles Run 0/30/45/60/75/90-degree Emery render gates.
  test-render-performance  Run fixture bearing and tile-animation matrix assertions.
  test-pan-under-load [prompt]
                           Run pan/load assertions, or only the prompt fade case.
  test-rapid-zoom-reversal Run A-to-B-to-A fallback eviction/refetch assertions.
  test-motion-reacquire    Replay wrist motion and assert fast bearing behavior.
  build                    Build the Pebble watch app.
  build-fixture            Build with emulator fixture PKJS bundled.
  build-real-fixture       Build with the local provider-map fixture bundled.
  build-fixture-animation  Build fixture mode with delayed animated tile loads.
  build-phone              Build with production phone/native mode bundled.
  install                  Build, launch the emulator, and install the app.
  install-fixture          Build/install with emulator fixture PKJS bundled.
  install-real-fixture     Build/install with the local provider-map fixture.
  install-fixture-animation
                           Build/install fixture mode with delayed animated tiles.
  install-phone            Build/install with production phone/native mode.
  wipe                     Wipe Pebble emulator data for the active SDK.
  screenshot [filename]    Capture emulator output as PNG.
  capture                  Build, install, then write latest.png.
  capture-fixture          Build/install/capture with emulator fixture PKJS.
  capture-real-fixture     Build/install/capture with the local provider-map fixture.
  capture-fixture-animation
                           Build/install/capture delayed animated tile fixture.
  record-fixture-animation [out-dir]
                           Build/install delayed fixture, relaunch, capture QEMU frames.
  capture-phone            Build/install/capture with production phone/native mode.
  smoke-fixture            Build/install/capture fixture mode, verify output, then stop.
  generate-real-fixture    Generate ignored provider-map fixture files using the
                           Pebble Tool Python environment.
  debug-compass <degrees|clear>
                           Inject a watch-side compass heading for emulator rotation tests.
  debug-facing <degrees|clear>
                           Enable face-forward orientation, then inject a debug compass heading.
  debug-manual-browse <degrees>
                           Enter fixture manual browse at the supplied heading.
  debug-location-position <screen-x> <screen-y> [degrees]
                           Project fixture GPS at a deterministic screen point.
  debug-recenter <degrees> Recenter the fixture and restore face-forward rotation.
  debug-map-settings <width> <height>
                            Send emulator map tile geometry settings to the watch.
  debug-tile [index]       Synthesize a decoded visible tile on the watch.
  debug-route-progress <percent>
                           Move debug GPS to a percent along the active route.
  debug-motion <fixture>   Replay stationary-raise or walking-to-look accel data.
  button <action> <button> Send emulator button input, e.g. "click select".
  kill                     Kill running Pebble emulators.

Environment:
  PEBBLE_PLATFORM          Pebble platform to emulate (default: emery).
  MAPPY_WATCH_PHONE_MODE   phone, fixture, or real-fixture (default: phone).
  PEBBLE_PHONE_MODE        Alias for MAPPY_WATCH_PHONE_MODE.
  PEBBLE_CAPTURE_DELAY_SECONDS
                           Delay before capture after install (default: 0,
                           capture-fixture default: 6).
  MAPPY_FIXTURE_TILE_DELAY_MS
                           Fixture-only tile response hold before first tile.
  MAPPY_FIXTURE_TILE_STAGGER_MS
                           Fixture-only extra delay per requested tile.
  MAPPY_FIXTURE_TILE_ANIMATION_MODE
                           Fixture startup tile animation sync: -1, 0, 1, or 2.
  MAPPY_FIXTURE_TILE_WIDTH Fixture tile width: 54, 72, or 108.
  MAPPY_FIXTURE_TILE_HEIGHT
                           Fixture tile height: 63, 84, or 126.
  MAPPY_FIXTURE_TILE_CHUNK_BYTES
                           Maximum deterministic tile chunk size: 128..3072.
  MAPPY_FIXTURE_TILE_HIGH_ENTROPY
                           Periodically inject a multi-chunk stress tile.
  MAPPY_FIXTURE_ROUTE_POINT_COUNT
                           Deterministic fixture route points: 3..128.
  MAPPY_FIXTURE_PHONE_READY_DELAY_MS
                           Delay version-2 phone-ready after INIT.
  MAPPY_FIXTURE_IGNORE_STARTUP_READY
                           Wait for INIT instead of pushing startup state.
  MAPPY_FIXTURE_IGNORE_FIRST_INIT
                           Drop the first INIT to exercise watch retry.
  MAPPY_FIXTURE_INJECT_STALE_TILE_FIRST
                           Send a stale tile request ID before the current tile.
  PEBBLE_WATCH_DIR         Watch app directory.
  PEBBLE_CODEX_OUT         Screenshot output directory.
  PEBBLE_PBW               Built .pbw path.
  PEBBLE_QEMU_CAPTURE_FRAMES
                           QEMU frames for record-fixture-animation (default: 60).
  PEBBLE_QEMU_CAPTURE_INTERVAL
                           QEMU frame interval in seconds (default: 0.2).
  PEBBLE_TOOL_PYTHON       Python interpreter from the Pebble Tool environment.
EOF
}

require_pebble() {
  if ! command -v pebble >/dev/null 2>&1; then
    echo "pebble CLI was not found on PATH" >&2
    exit 127
  fi
}

windows_path() {
  if command -v wslpath >/dev/null 2>&1; then
    wslpath -w "$1"
  else
    echo "$1"
  fi
}

normalize_phone_mode() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-')"
  case "$value" in
    phone|native|android|production|prod)
      printf 'phone'
      ;;
    fixture|fixtures|emulator-fixture|emulator-fixtures|test-fixture|test-fixtures)
      printf 'fixture'
      ;;
    real-fixture|real-fixtures|real-map-fixture|provider-fixture)
      printf 'real-fixture'
      ;;
    *)
      echo "Unsupported MAPPY_WATCH_PHONE_MODE '$1'. Use 'phone', 'fixture', or 'real-fixture'." >&2
      exit 2
      ;;
  esac
}

set_phone_mode() {
  PHONE_MODE="$(normalize_phone_mode "$1")"
}

set_animation_fixture_defaults() {
  set_phone_mode fixture
  export MAPPY_FIXTURE_TILE_DELAY_MS="${MAPPY_FIXTURE_TILE_DELAY_MS:-900}"
  export MAPPY_FIXTURE_TILE_STAGGER_MS="${MAPPY_FIXTURE_TILE_STAGGER_MS:-80}"
  export MAPPY_FIXTURE_TILE_ANIMATION_MODE="${MAPPY_FIXTURE_TILE_ANIMATION_MODE:-2}"
  export PEBBLE_CAPTURE_DELAY_SECONDS="${PEBBLE_CAPTURE_DELAY_SECONDS:-4}"
  CAPTURE_DELAY_SECONDS="$PEBBLE_CAPTURE_DELAY_SECONDS"
}

build_app() {
  require_pebble
  cd "$WATCH_DIR" || return
  export MAPPY_WATCH_PHONE_MODE
  MAPPY_WATCH_PHONE_MODE="$(normalize_phone_mode "$PHONE_MODE")"
  echo "Building Pebble watch app with MAPPY_WATCH_PHONE_MODE=$MAPPY_WATCH_PHONE_MODE"
  pebble build
}

install_app() {
  build_app || return
  cd "$WATCH_DIR" || return
  pebble install --emulator "$PLATFORM" --force "$PBW_PATH"
}

wipe_emulator() {
  require_pebble
  pebble wipe
}

install_app_with_recovery() {
  if install_app; then
    return 0
  fi

  echo "Install failed; wiping Pebble emulator data and retrying once..." >&2
  wipe_emulator
  install_app
}

capture_after_install() {
  install_app_with_recovery || return
  if [[ "$CAPTURE_DELAY_SECONDS" != "0" ]]; then
    sleep "$CAPTURE_DELAY_SECONDS"
  fi
  capture_screenshot latest.png
}

capture_screenshot() {
  require_pebble
  mkdir -p "$OUT_DIR"

  local filename="${1:-latest.png}"
  local output_path="$filename"
  if [[ "$output_path" != /* ]]; then
    output_path="$OUT_DIR/$output_path"
  fi

  cd "$WATCH_DIR" || return
  pebble screenshot --emulator "$PLATFORM" --no-open "$output_path"
  echo "Screenshot: $(windows_path "$output_path")"
}

app_uuid() {
  python3 -c 'import json; print(json.load(open("package.json"))["pebble"]["uuid"])'
}

pebble_tool_python() {
  if [[ -n "${PEBBLE_TOOL_PYTHON:-}" ]]; then
    printf '%s\n' "$PEBBLE_TOOL_PYTHON"
    return
  fi

  local pebble_path candidate shebang
  pebble_path="$(command -v pebble)"
  shebang="$(head -n 1 "$pebble_path")"
  candidate="${shebang#\#!}"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  candidate="$(dirname "$(readlink -f "$pebble_path")")/python3"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  candidate="$(dirname "$(readlink -f "$pebble_path")")/python"
  if [[ -x "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return
  fi

  if python3 -c 'import libpebble2' >/dev/null 2>&1; then
    command -v python3
    return
  fi

  echo "Pebble Tool Python was not found; set PEBBLE_TOOL_PYTHON." >&2
  return 1
}

doctor() {
  require_pebble

  local required version_output sdk_inventory active_sdk include_path sdk_root qemu_path tool_python
  for required in python3 node npm; do
    if ! command -v "$required" >/dev/null 2>&1; then
      echo "Required command was not found: $required" >&2
      return 1
    fi
  done

  version_output="$(pebble --version 2>&1)"
  sdk_inventory="$(pebble sdk list 2>&1)"
  printf '%s\n%s\n' "$version_output" "$sdk_inventory"

  if grep -Fq "A new pebble-tool is available" <<<"$sdk_inventory"; then
    echo "Pebble Tool is not current; run tooling/bootstrap-pebble-sdk-wsl.sh." >&2
    return 1
  fi
  if grep -Fq "A new SDK is available" <<<"$sdk_inventory"; then
    echo "The active Pebble SDK is not current; run tooling/bootstrap-pebble-sdk-wsl.sh." >&2
    return 1
  fi

  active_sdk="$(sed -nE 's/.*active SDK: v([^)]*).*/\1/p' <<<"$version_output")"
  if [[ -z "$active_sdk" ]]; then
    echo "Pebble Tool did not report an active SDK." >&2
    return 1
  fi

  include_path="$(pebble sdk include-path "$PLATFORM")"
  if [[ ! -d "$include_path" ]]; then
    echo "SDK include path does not exist for $PLATFORM: $include_path" >&2
    return 1
  fi
  sdk_root="$(cd "$include_path/../../../.." && pwd)"
  qemu_path="$sdk_root/toolchain/bin/qemu-pebble"
  if [[ ! -x "$qemu_path" ]]; then
    echo "Pebble QEMU executable was not found: $qemu_path" >&2
    return 1
  fi

  tool_python="$(pebble_tool_python)"
  "$tool_python" -c 'import libpebble2; from PIL import Image' >/dev/null
  bash -n "$ROOT_DIR/tooling/bootstrap-pebble-sdk-wsl.sh"
  bash -n "$ROOT_DIR/tooling/pebble-emulator-codex.sh"

  printf 'Platform: %s\nSDK include: %s\n' "$PLATFORM" "$include_path"
  "$qemu_path" --version | head -n 1
  printf 'Pebble development environment is ready.\n'
}

test_tooling() {
  require_pebble
  "$(pebble_tool_python)" "$ROOT_DIR/tooling/test-pebble-development.py"
  test_motion_host
  test_navigation_feedback_host
  test_pan_inertia_host
  test_tile_cache_host
  test_tile_scheduler_host
  test_face_forward_render_host
  test_location_edge_host
}

test_protocol() {
  python3 "$ROOT_DIR/tooling/test-protocol-consistency.py"
}

test_motion_host() {
  local compiler="${CC:-cc}"
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C compiler was not found: $compiler" >&2
    return 127
  fi
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/mappy-motion-tests.XXXXXX")"
  trap 'rm -f "$output"' RETURN
  "$compiler" -std=c99 -Wall -Wextra -Werror \
    "$ROOT_DIR/tooling/test-motion-detector.c" \
    "$WATCH_DIR/src/c/motion_detector.c" \
    "$WATCH_DIR/src/c/bearing_smoothing.c" \
    -o "$output"
  cd "$ROOT_DIR"
  "$output"
  rm -f "$output"
  trap - RETURN
}

test_navigation_feedback_host() {
  local compiler="${CC:-cc}"
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C compiler was not found: $compiler" >&2
    return 127
  fi
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/mappy-navigation-feedback-tests.XXXXXX")"
  trap 'rm -f "$output"' RETURN
  "$compiler" -std=c99 -Wall -Wextra -Werror \
    "$ROOT_DIR/tooling/test-navigation-feedback.c" \
    "$WATCH_DIR/src/c/navigation_feedback.c" \
    -o "$output"
  "$output"
  rm -f "$output"
  trap - RETURN
}

test_pan_inertia_host() {
  local compiler="${CC:-cc}"
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C compiler was not found: $compiler" >&2
    return 127
  fi
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/mappy-pan-inertia-tests.XXXXXX")"
  trap 'rm -f "$output"' RETURN
  "$compiler" -std=c99 -Wall -Wextra -Werror \
    "$ROOT_DIR/tooling/test-pan-inertia.c" \
    "$WATCH_DIR/src/c/pan_inertia.c" \
    -o "$output"
  "$output"
  rm -f "$output"
  trap - RETURN
}

test_tile_cache_host() {
  local compiler="${CC:-cc}"
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C compiler was not found: $compiler" >&2
    return 127
  fi
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/mappy-tile-cache-tests.XXXXXX")"
  trap 'rm -f "$output"' RETURN
  "$compiler" -std=c99 -Wall -Wextra -Werror \
    "$ROOT_DIR/tooling/test-tile-storage.c" \
    "$WATCH_DIR/src/c/tile_codec.c" \
    "$WATCH_DIR/src/c/tile_storage.c" \
    -o "$output"
  "$output"
  rm -f "$output"
  trap - RETURN
}

test_tile_scheduler_host() {
  local compiler="${CC:-cc}"
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C compiler was not found: $compiler" >&2
    return 127
  fi
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/mappy-tile-scheduler-tests.XXXXXX")"
  trap 'rm -f "$output"' RETURN
  "$compiler" -std=c99 -Wall -Wextra -Werror -DMAPPY_H \
    -include "$ROOT_DIR/tooling/tile-requests-host-shim.h" \
    "$ROOT_DIR/tooling/test-tile-request-scheduler.c" \
    "$WATCH_DIR/src/c/tile_requests.c" \
    -o "$output"
  "$output"
  rm -f "$output"
  trap - RETURN
}

test_face_forward_render_host() {
  local compiler="${CC:-cc}"
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C compiler was not found: $compiler" >&2
    return 127
  fi

  local raster_output benchmark_output
  raster_output="$(mktemp "${TMPDIR:-/tmp}/mappy-rotated-raster-tests.XXXXXX")"
  benchmark_output="$(mktemp "${TMPDIR:-/tmp}/mappy-face-forward-benchmark.XXXXXX")"
  trap 'rm -f "$raster_output" "$benchmark_output"' RETURN

  "$compiler" -std=c99 -Wall -Wextra -Werror -O2 \
    "$ROOT_DIR/tooling/test-rotated-raster.c" -lm -o "$raster_output"
  "$raster_output"

  "$compiler" -std=c99 -Wall -Wextra -Werror -O2 \
    "$ROOT_DIR/tooling/face-forward-render-benchmark.c" -lm \
    -o "$benchmark_output"
  "$benchmark_output"

  rm -f "$raster_output" "$benchmark_output"
  trap - RETURN
}

test_location_edge_host() {
  local compiler="${CC:-cc}"
  if ! command -v "$compiler" >/dev/null 2>&1; then
    echo "C compiler was not found: $compiler" >&2
    return 127
  fi
  local output
  output="$(mktemp "${TMPDIR:-/tmp}/mappy-location-edge-tests.XXXXXX")"
  trap 'rm -f "$output"' RETURN
  "$compiler" -std=c99 -Wall -Wextra -Werror \
    "$ROOT_DIR/tooling/test-location-edge-geometry.c" \
    "$WATCH_DIR/src/c/location_edge_geometry.c" \
    -o "$output"
  "$output"
  rm -f "$output"
  trap - RETURN
}

generate_real_fixture() {
  require_pebble
  cd "$ROOT_DIR" || return
  "$(pebble_tool_python)" "$ROOT_DIR/tooling/generate-real-map-fixtures.py" "$@"
}

smoke_fixture() {
  set_phone_mode fixture
  if [[ -z "${PEBBLE_CAPTURE_DELAY_SECONDS:-}" ]]; then
    CAPTURE_DELAY_SECONDS=6
  fi
  local status=0
  if capture_after_install; then
    if [[ ! -s "$OUT_DIR/latest.png" ]]; then
      echo "Fixture screenshot was not created or is empty: $OUT_DIR/latest.png" >&2
      status=1
    else
      echo "Fixture smoke screenshot: $(windows_path "$OUT_DIR/latest.png")"
    fi
  else
    status=$?
  fi
  pebble kill >/dev/null 2>&1 || true
  return "$status"
}

record_fixture_animation() {
  set_animation_fixture_defaults
  pebble kill >/dev/null 2>&1 || true
  install_app_with_recovery

  local output_path="${1:-}"
  if [[ -z "$output_path" ]]; then
    output_path="$OUT_DIR/tile-video/fixture-animation-$(date +%Y%m%d-%H%M%S)"
  fi
  if [[ "$output_path" != /* ]]; then
    output_path="$OUT_DIR/$output_path"
  fi

  local frames="${PEBBLE_QEMU_CAPTURE_FRAMES:-60}"
  local interval="${PEBBLE_QEMU_CAPTURE_INTERVAL:-0.2}"
  cd "$WATCH_DIR"
  "$(pebble_tool_python)" \
    "$ROOT_DIR/tooling/pebble-qemu-capture.py" \
    --platform "$PLATFORM" \
    --out-dir "$output_path" \
    --frames "$frames" \
    --interval-seconds "$interval"
  echo "Frames: $(windows_path "$output_path")"
}

send_button() {
  require_pebble
  if [[ $# -lt 2 ]]; then
    echo "button requires an action and at least one button" >&2
    echo "Example: $(basename "$0") button click select" >&2
    exit 2
  fi
  pebble emu-button --emulator "$PLATFORM" "$@"
}

debug_compass_value() {
  local raw="${1:-}"
  case "$raw" in
    clear|invalid|off|none|-1)
      printf '%s' "-1"
      ;;
    ''|*[!0-9]*)
      echo "debug compass requires degrees 0..359 or 'clear'" >&2
      exit 2
      ;;
    *)
      local value=$((10#$raw))
      if (( value < 0 || value > 359 )); then
        echo "debug compass degrees must be 0..359" >&2
        exit 2
      fi
      printf '%s' "$value"
      ;;
  esac
}

send_debug_compass() {
  require_pebble
  if [[ $# -ne 1 ]]; then
    echo "debug-compass requires degrees 0..359 or 'clear'" >&2
    exit 2
  fi
  local heading
  heading="$(debug_compass_value "$1")"
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=901 60="$heading"
}

send_debug_compass_mixed() {
  require_pebble
  local heading
  heading="$(debug_compass_value "$1")"
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=901 51=1 60="$heading"
}

send_debug_compass_manual_browse() {
  require_pebble
  if [[ $# -ne 1 ]]; then
    echo "debug-manual-browse requires degrees 0..359" >&2
    exit 2
  fi
  local heading
  heading="$(debug_compass_value "$1")"
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=901 52=1 60="$heading"
}

send_debug_location_position() {
  require_pebble
  if [[ $# -lt 2 || $# -gt 3 || ! "$1" =~ ^-?[0-9]+$ ||
        ! "$2" =~ ^-?[0-9]+$ ]]; then
    echo "debug-location-position requires integer screen-x screen-y and optional degrees" >&2
    exit 2
  fi
  local heading
  heading="$(debug_compass_value "${3:-35}")"
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=901 52=3 60="$heading" 63="$1" 64="$2"
}

send_debug_compass_recenter() {
  require_pebble
  if [[ $# -ne 1 ]]; then
    echo "debug-recenter requires degrees 0..359" >&2
    exit 2
  fi
  local heading
  heading="$(debug_compass_value "$1")"
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=901 52=2 60="$heading"
}

send_fixture_map_orientation() {
  require_pebble
  local orientation="$1"
  if [[ "$orientation" != "0" && "$orientation" != "1" ]]; then
    echo "fixture map orientation must be 0 (north) or 1 (facing)" >&2
    return 2
  fi
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=205 60="$orientation"
}

send_fixture_tile_animation() {
  require_pebble
  local animation="$1"
  if [[ "$animation" != "0" && "$animation" != "1" &&
        "$animation" != "2" ]]; then
    echo "fixture tile animation must be 0, 1, or 2" >&2
    return 2
  fi
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=206 60="$animation"
}

send_debug_pan_under_load() {
  require_pebble
  if [[ $# -ne 1 ]]; then
    echo "debug pan fixture requires an action" >&2
    return 2
  fi
  cd "$WATCH_DIR"
  # Fixture-only camera control 4; width carries the action. Production
  # protocol is unchanged.
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=901 51="$1" 52=4 60=0
}

send_debug_facing() {
  require_pebble
  if [[ $# -ne 1 ]]; then
    echo "debug-facing requires degrees 0..359 or 'clear'" >&2
    exit 2
  fi
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=205 60=1
  sleep 0.15
  send_debug_compass "$1"
}

send_debug_map_settings() {
  require_pebble
  if [[ $# -ne 2 ]]; then
    echo "debug-map-settings requires width and height" >&2
    exit 2
  fi
  local width="$1"
  local height="$2"
  case "$width:$height" in
    54:63|72:84|108:126)
      ;;
    *)
      echo "debug-map-settings supports 54x63, 72x84, or 108x126" >&2
      exit 2
      ;;
  esac
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=204 51="$width" 52="$height" 54=1
}

send_debug_tile() {
  require_pebble
  local index="${1:-0}"
  case "$index" in
    ''|*[!0-9]*)
      echo "debug-tile index must be a non-negative integer" >&2
      exit 2
      ;;
  esac
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=902 60="$((10#$index))"
}

send_debug_route_progress() {
  require_pebble
  if [[ $# -ne 1 ]]; then
    echo "debug-route-progress requires a percent from 0 to 100" >&2
    exit 2
  fi
  local raw="${1%\%}"
  case "$raw" in
    ''|*[!0-9]*)
      echo "debug-route-progress percent must be an integer from 0 to 100" >&2
      exit 2
      ;;
  esac
  local percent=$((10#$raw))
  if (( percent < 0 || percent > 100 )); then
    echo "debug-route-progress percent must be 0..100" >&2
    exit 2
  fi
  local permille=$((percent * 10))
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=903 60="$permille"
}

send_debug_motion() {
  require_pebble
  if [[ $# -ne 1 ]]; then
    echo "debug-motion requires stationary-raise or walking-to-look" >&2
    exit 2
  fi
  local fixture="$1"
  case "$fixture" in
    stationary-raise|walking-to-look)
      ;;
    *)
      echo "Unknown motion fixture: $fixture" >&2
      exit 2
      ;;
  esac
  local fixture_path="$ROOT_DIR/tooling/motion-fixtures/$fixture.csv"
  if [[ ! -s "$fixture_path" ]]; then
    echo "Motion fixture was not found: $fixture_path" >&2
    return 1
  fi
  pebble emu-accel --emulator "$PLATFORM" custom "$fixture_path"
}

perf_summary_value() {
  local line="$1"
  local key="$2"
  sed -nE "s/.*(^|[[:space:]])${key}=([0-9]+).*/\\2/p" <<<"$line"
}

perf_summary_signed_value() {
  local line="$1"
  local key="$2"
  sed -nE "s/.*(^|[[:space:]])${key}=(-?[0-9]+).*/\\2/p" <<<"$line"
}

perf_summary_pair_value() {
  local line="$1"
  local key="$2"
  local component="$3"
  local pair
  pair="$(sed -nE "s/.*(^|[[:space:]])${key}=([0-9]+\/[0-9]+).*/\\2/p" <<<"$line")"
  if [[ "$component" == "total" ]]; then
    printf '%s\n' "${pair%%/*}"
  else
    printf '%s\n' "${pair##*/}"
  fi
}

test_render_performance() {
  require_pebble
  set_phone_mode fixture
  export MAPPY_FIXTURE_ROUTE_POINT_COUNT=128
  export MAPPY_FIXTURE_TILE_ANIMATION_MODE=0
  export MAPPY_FIXTURE_TILE_DELAY_MS=0
  export MAPPY_FIXTURE_TILE_STAGGER_MS=0
  mkdir -p "$OUT_DIR"
  local log_file="$OUT_DIR/render-performance.log"
  rm -f "$log_file"

  pebble kill >/dev/null 2>&1 || true
  install_app_with_recovery
  sleep 6

  cd "$WATCH_DIR"
  PYTHONUNBUFFERED=1 pebble logs --emulator "$PLATFORM" >"$log_file" 2>&1 &
  local log_pid=$!
  trap 'kill "$log_pid" >/dev/null 2>&1 || true' RETURN
  sleep 1

  send_debug_facing 0
  sleep 3
  # Warm both small-angle tile envelopes before the isolated measurement.
  send_debug_compass 4
  sleep 3
  send_debug_compass 0
  sleep 3
  send_debug_compass 4
  sleep 2

  # Measure the same facing-up mixed workload with every tile animation mode.
  # Reset through manual browse before each case so GPS, menu, and camera state
  # do not leak into the next result. Force animation off while resetting so a
  # recenter-triggered tile response cannot overlap the measured animation.
  # These controls do not begin a measurement.
  local mixed_modes=(0 1 2)
  # Hold the bearing steady so the same animated tile cannot rotate out of the
  # visible coverage before its mode reaches the completion deadline.
  local mixed_headings=(4 4 4)
  local mixed_current_heading=4
  local mixed_index
  for mixed_index in "${!mixed_modes[@]}"; do
    send_fixture_tile_animation 0
    sleep 0.15
    send_debug_compass_manual_browse "$mixed_current_heading"
    sleep 0.15
    send_debug_compass_recenter "$mixed_current_heading"
    sleep 0.35
    send_fixture_tile_animation "${mixed_modes[mixed_index]}"
    sleep 0.15
    send_debug_compass_mixed "${mixed_headings[mixed_index]}"
    sleep 3
    mixed_current_heading="${mixed_headings[mixed_index]}"
  done

  send_debug_compass_manual_browse 200
  sleep 2
  send_debug_compass 20
  sleep 3

  send_debug_compass_recenter 20
  sleep 2
  send_debug_compass 4
  sleep 3

  send_debug_compass clear
  sleep 1

  kill "$log_pid" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true
  trap - RETURN

  mapfile -t summaries < <(grep 'MAPPY_PERF' "$log_file")
  mapfile -t rotated_summaries < <(grep 'MAPPY_RPERF' "$log_file")
  if (( ${#summaries[@]} < 9 || ${#rotated_summaries[@]} < 9 )); then
    echo "Expected at least nine MAPPY_PERF/RPERF summary pairs; see $(windows_path "$log_file")" >&2
    return 1
  fi
  local isolated="${summaries[${#summaries[@]}-6]}"
  local mixed_none="${summaries[${#summaries[@]}-5]}"
  local mixed_fade="${summaries[${#summaries[@]}-4]}"
  local mixed_zoom="${summaries[${#summaries[@]}-3]}"
  local mixed_none_rotated="${rotated_summaries[${#rotated_summaries[@]}-5]}"
  local mixed_fade_rotated="${rotated_summaries[${#rotated_summaries[@]}-4]}"
  local mixed_zoom_rotated="${rotated_summaries[${#rotated_summaries[@]}-3]}"
  # Preserve the original mixed-source assertions against the fade case.
  local mixed="$mixed_fade"
  local manual="${summaries[${#summaries[@]}-2]}"
  local recentered="${summaries[${#summaries[@]}-1]}"
  local isolated_draws isolated_steps isolated_projections
  local mixed_multi mixed_ticks mixed_draws mixed_gps mixed_tiles mixed_menu
  local mixed_clipped mixed_errors
  local manual_ticks manual_draws manual_steps manual_advances manual_browse
  local manual_map_errors manual_projections manual_orientation_work manual_errors
  local recentered_ticks recentered_steps recentered_browse
  local recentered_orientation_work recentered_errors
  local isolated_draw_max mixed_draw_max manual_draw_max recentered_draw_max
  isolated_draws="$(perf_summary_value "$isolated" d)"
  isolated_steps="$(perf_summary_value "$isolated" b)"
  isolated_projections="$(perf_summary_value "$isolated" p)"
  mixed_multi="$(perf_summary_value "$mixed" x)"
  mixed_ticks="$(perf_summary_value "$mixed" t)"
  mixed_draws="$(perf_summary_value "$mixed" d)"
  mixed_gps="$(perf_summary_value "$mixed" g)"
  mixed_tiles="$(perf_summary_value "$mixed" l)"
  mixed_menu="$(perf_summary_value "$mixed" m)"
  mixed_clipped="$(perf_summary_value "$mixed" c)"
  mixed_errors="$(perf_summary_value "$mixed" e)"
  manual_ticks="$(perf_summary_value "$manual" t)"
  manual_draws="$(perf_summary_value "$manual" d)"
  manual_steps="$(perf_summary_value "$manual" b)"
  manual_advances="$(perf_summary_value "$manual" B)"
  manual_browse="$(perf_summary_value "$manual" u)"
  manual_map_errors="$(perf_summary_value "$manual" v)"
  manual_projections="$(perf_summary_value "$manual" p)"
  manual_orientation_work="$(perf_summary_value "$manual" o)"
  manual_errors="$(perf_summary_value "$manual" e)"
  recentered_ticks="$(perf_summary_value "$recentered" t)"
  recentered_steps="$(perf_summary_value "$recentered" b)"
  recentered_browse="$(perf_summary_value "$recentered" u)"
  recentered_orientation_work="$(perf_summary_value "$recentered" o)"
  recentered_errors="$(perf_summary_value "$recentered" e)"
  isolated_draw_max="$(perf_summary_pair_value "$isolated" q max)"
  mixed_draw_max="$(perf_summary_pair_value "$mixed" q max)"
  manual_draw_max="$(perf_summary_pair_value "$manual" q max)"
  recentered_draw_max="$(perf_summary_pair_value "$recentered" q max)"

  if [[ -z "$isolated_draws" || "$isolated_draws" != "$isolated_steps" ]]; then
    echo "Bearing redraw assertion failed: $isolated" >&2
    return 1
  fi
  if [[ -z "$isolated_projections" ]] || (( isolated_projections > 1 )); then
    echo "Bearing projection-cache assertion failed: $isolated" >&2
    return 1
  fi
  if [[ -z "$mixed_multi" ]] || (( mixed_multi < 1 )); then
    echo "Mixed scheduler assertion failed: $mixed" >&2
    return 1
  fi
  if [[ -z "$mixed_gps" || -z "$mixed_tiles" || -z "$mixed_menu" ]] ||
      (( mixed_gps < 1 || mixed_tiles < 1 || mixed_menu < 1 )); then
    echo "Mixed source-advance assertion failed: $mixed" >&2
    return 1
  fi
  if [[ -z "$mixed_ticks" || -z "$mixed_draws" ]] || (( mixed_draws < mixed_ticks )); then
    echo "Mixed redraw assertion failed: $mixed" >&2
    return 1
  fi
  if [[ -z "$mixed_clipped" ]] || (( mixed_clipped < 1 )); then
    echo "Offscreen clipping assertion failed: $mixed" >&2
    return 1
  fi
  if [[ -z "$mixed_errors" || "$mixed_errors" != "0" ]]; then
    echo "Fixture performance errors reported: $mixed" >&2
    return 1
  fi

  # The 180/220 ms animation contract should need no more than seven/eight
  # tile advances with one cadence of timing tolerance. GPS and menu work can
  # continue after the tile completes, so gate tile lifetime directly and use
  # per-frame latency (not aggregate draw count/time) for responsiveness. This
  # still prevents the old 480/640 ms animation lifetimes from returning.
  local matrix_summaries=("$mixed_none" "$mixed_fade" "$mixed_zoom")
  local matrix_rotated_summaries=(
    "$mixed_none_rotated" "$mixed_fade_rotated" "$mixed_zoom_rotated")
  local matrix_names=("none" "fade" "fade+zoom")
  local matrix_min_tile_ticks=(0 5 6)
  local matrix_max_tile_ticks=(0 7 8)
  local matrix_summary matrix_name matrix_errors matrix_ticks
  local matrix_draws matrix_tiles matrix_draw_total matrix_draw_max
  local matrix_decode_errors
  for mixed_index in "${!matrix_summaries[@]}"; do
    matrix_summary="${matrix_summaries[mixed_index]}"
    matrix_name="${matrix_names[mixed_index]}"
    matrix_errors="$(perf_summary_value "$matrix_summary" e)"
    matrix_ticks="$(perf_summary_value "$matrix_summary" t)"
    matrix_draws="$(perf_summary_value "$matrix_summary" d)"
    matrix_tiles="$(perf_summary_value "$matrix_summary" l)"
    matrix_draw_total="$(perf_summary_pair_value "$matrix_summary" q total)"
    matrix_draw_max="$(perf_summary_pair_value "$matrix_summary" q max)"
    matrix_decode_errors="$(perf_summary_value \
        "${matrix_rotated_summaries[mixed_index]}" e)"

    if [[ -z "$matrix_errors" || "$matrix_errors" != "0" ]]; then
      echo "Tile animation $matrix_name reported errors: $matrix_summary" >&2
      return 1
    fi
    if [[ -z "$matrix_ticks" || -z "$matrix_draws" ||
          -z "$matrix_tiles" || -z "$matrix_draw_total" ||
          -z "$matrix_draw_max" ]] ||
        (( matrix_ticks < 1 || matrix_ticks > 64 ||
           matrix_draws < 1 ||
           matrix_draws > matrix_ticks + 1 )); then
      echo "Tile animation $matrix_name redraw/tick budget failed: scheduler=${matrix_ticks:-missing}/64 draws=${matrix_draws:-missing} summary=$matrix_summary" >&2
      return 1
    fi
    if (( mixed_index == 0 )); then
      if (( matrix_tiles != 0 )); then
        echo "Disabled tile animation advanced unexpectedly: $matrix_summary" >&2
        return 1
      fi
    elif (( matrix_tiles < matrix_min_tile_ticks[mixed_index] ||
            matrix_tiles > matrix_max_tile_ticks[mixed_index] ||
            matrix_draws < matrix_tiles )); then
      echo "Tile animation $matrix_name lifetime budget failed: tileTicks=${matrix_tiles}/${matrix_min_tile_ticks[mixed_index]}..${matrix_max_tile_ticks[mixed_index]} draws=$matrix_draws summary=$matrix_summary" >&2
      return 1
    fi
    # RPERF z measures cross-zoom fallback sampling, not tile-local animation
    # scale. Keep the renderer integrity gate to decode failures; the isolated
    # setting/reset sequence and tile lifetime counters distinguish the modes.
    if [[ -z "$matrix_decode_errors" || "$matrix_decode_errors" != "0" ]]; then
      echo "Tile animation $matrix_name renderer decode assertion failed: decodeErrors=${matrix_decode_errors:-missing} summary=${matrix_rotated_summaries[mixed_index]}" >&2
      return 1
    fi
    if (( matrix_draw_total < matrix_draw_max || matrix_draw_max > 28 ||
          matrix_draw_total > matrix_draws * 25 )); then
      echo "Tile animation $matrix_name render budget failed: total=${matrix_draw_total}ms draws=${matrix_draws} averageLimit=25ms max=${matrix_draw_max}/28ms" >&2
      return 1
    fi
  done

  if [[ -z "$manual_ticks" || -z "$manual_draws" || -z "$manual_steps" ||
        -z "$manual_advances" || -z "$manual_browse" ]] ||
      (( manual_ticks < 2 || manual_draws != manual_steps ||
         manual_advances < manual_steps ||
         manual_browse != manual_advances )); then
    echo "Manual-browse bearing animation assertion failed: $manual" >&2
    return 1
  fi
  if [[ -z "$manual_projections" || "$manual_projections" != "0" ||
        -z "$manual_orientation_work" || "$manual_orientation_work" != "0" ]]; then
    echo "Manual-browse map isolation assertion failed: $manual" >&2
    return 1
  fi
  if [[ -z "$manual_map_errors" || "$manual_map_errors" != "0" ]]; then
    echo "Manual-browse map-bearing assertion failed: $manual" >&2
    return 1
  fi
  if [[ -z "$manual_errors" || "$manual_errors" != "0" ]]; then
    echo "Manual-browse fixture errors reported: $manual" >&2
    return 1
  fi

  if [[ -z "$recentered_ticks" || -z "$recentered_steps" ]] ||
      (( recentered_ticks < 2 || recentered_steps < 2 ||
         recentered_steps > recentered_ticks )); then
    echo "Recentered bearing animation assertion failed: $recentered" >&2
    return 1
  fi
  if [[ -z "$recentered_browse" || "$recentered_browse" != "0" ||
        -z "$recentered_orientation_work" ]] ||
      (( recentered_orientation_work != recentered_steps )); then
    echo "Recentered map-orientation assertion failed: $recentered" >&2
    return 1
  fi
  if [[ -z "$recentered_errors" || "$recentered_errors" != "0" ]]; then
    echo "Recentered fixture errors reported: $recentered" >&2
    return 1
  fi

  if [[ -z "$isolated_draw_max" || -z "$mixed_draw_max" ||
        -z "$manual_draw_max" || -z "$recentered_draw_max" ]]; then
    echo "Render timing summary was missing q=total/max: $recentered" >&2
    return 1
  fi
  if (( isolated_draw_max > 20 || mixed_draw_max > 40 ||
        recentered_draw_max > 30 )); then
    echo "Facing render regression: isolated=$isolated_draw_max/20ms mixed=$mixed_draw_max/40ms recentered=$recentered_draw_max/30ms" >&2
    return 1
  fi
  if (( manual_draw_max > 50 )); then
    echo "North-up manual-browse render exceeded 50 ms: $manual_draw_max" >&2
    return 1
  fi

  printf 'Isolated: %s\nAnimation none: %s\nAnimation fade: %s\nAnimation fade+zoom: %s\nManual browse: %s\nRecentered: %s\nPerformance log: %s\n' \
    "$isolated" "$mixed_none" "$mixed_fade" "$mixed_zoom" \
    "$manual" "$recentered" \
    "$(windows_path "$log_file")"
  pebble kill >/dev/null 2>&1 || true
}

test_face_forward_angles() {
  require_pebble
  set_phone_mode fixture
  export MAPPY_FIXTURE_ROUTE_POINT_COUNT=128
  export MAPPY_FIXTURE_TILE_ANIMATION_MODE=0
  export MAPPY_FIXTURE_TILE_DELAY_MS=0
  export MAPPY_FIXTURE_TILE_STAGGER_MS=0
  mkdir -p "$OUT_DIR"
  local log_file="$OUT_DIR/face-forward-angle-sweep.log"
  rm -f "$log_file"

  pebble kill >/dev/null 2>&1 || true
  install_app_with_recovery
  sleep 6

  cd "$WATCH_DIR"
  PYTHONUNBUFFERED=1 pebble logs --emulator "$PLATFORM" >"$log_file" 2>&1 &
  local log_pid=$!
  trap 'kill "$log_pid" >/dev/null 2>&1 || true' RETURN
  sleep 1

  local angles=(0 30 45 60 75 90)
  send_debug_facing 0
  sleep 3
  for angle in "${angles[@]:1}"; do
    send_debug_compass "$angle"
    sleep 3
  done

  kill "$log_pid" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true
  trap - RETURN

  mapfile -t summaries < <(grep 'MAPPY_PERF' "$log_file")
  mapfile -t rotated < <(grep 'MAPPY_RPERF' "$log_file")
  local expected=${#angles[@]}
  if (( ${#summaries[@]} < expected || ${#rotated[@]} < expected )); then
    echo "Expected $expected face-forward summaries; see $(windows_path "$log_file")" >&2
    pebble kill >/dev/null 2>&1 || true
    return 1
  fi

  local first_summary=$((${#summaries[@]} - expected))
  local first_rotated=$((${#rotated[@]} - expected))
  for i in "${!angles[@]}"; do
    local summary="${summaries[first_summary + i]}"
    local render_summary="${rotated[first_rotated + i]}"
    local draw_max render_errors passes destination_pixels sample_attempts
    local packed_hits rle_hits rle_misses rle_decoded
    draw_max="$(perf_summary_pair_value "$summary" q max)"
    render_errors="$(perf_summary_value "$render_summary" e)"
    passes="$(perf_summary_value "$render_summary" a)"
    destination_pixels="$(perf_summary_value "$render_summary" p)"
    sample_attempts="$(perf_summary_value "$render_summary" s)"
    packed_hits="$(perf_summary_value "$render_summary" k)"
    rle_hits="$(perf_summary_value "$render_summary" h)"
    rle_misses="$(perf_summary_value "$render_summary" m)"
    rle_decoded="$(perf_summary_value "$render_summary" r)"
    if [[ -z "$draw_max" || -z "$render_errors" || -z "$passes" ||
          -z "$destination_pixels" || -z "$sample_attempts" ||
          -z "$packed_hits" || -z "$rle_hits" || -z "$rle_misses" ||
          -z "$rle_decoded" ||
          "$render_errors" != "0" ]] ||
        (( draw_max > 50 || (i > 0 && passes < 1) ||
           destination_pixels != sample_attempts ||
           packed_hits + rle_hits + rle_misses > sample_attempts ||
           rle_decoded > 32 * rle_misses )); then
      echo "Face-forward ${angles[i]}-degree render gate failed: $summary / $render_summary" >&2
      pebble kill >/dev/null 2>&1 || true
      return 1
    fi
    printf '%s degrees: %s\n  %s\n' "${angles[i]}" "$summary" "$render_summary"
  done
  printf 'Angle performance log: %s\n' "$(windows_path "$log_file")"
  pebble kill >/dev/null 2>&1 || true
}

run_pan_under_load_case() {
  local width="$1"
  local height="$2"
  local orientation="$3"
  local animation="$4"
  local prompt_animation="${5:-0}"
  local orientation_name="north"
  if [[ "$orientation" == "1" ]]; then
    orientation_name="facing"
  fi
  local label="${width}x${height}-${orientation_name}-anim${animation}"
  if [[ "$prompt_animation" == "1" ]]; then
    label="${label}-prompt"
  fi
  local log_file="$OUT_DIR/pan-under-load-${label}.log"
  local expected_tiles=25
  if [[ "$width" == "72" ]]; then
    expected_tiles=16
  elif [[ "$width" == "108" ]]; then
    expected_tiles=9
  fi
  rm -f "$log_file"

  cd "$WATCH_DIR"
  PYTHONUNBUFFERED=1 pebble logs --emulator "$PLATFORM" >"$log_file" 2>&1 &
  local log_pid=$!
  sleep 1
  send_fixture_map_orientation "$orientation"
  sleep 0.15
  send_fixture_tile_animation "$animation"
  sleep 0.15
  send_debug_compass_recenter 0
  sleep 0.35
  if [[ "$prompt_animation" == "1" ]]; then
    send_debug_tile 0
    local seed_deadline=$((SECONDS + 2))
    while (( SECONDS < seed_deadline )); do
      if grep -q 'Debug tile accept' "$log_file"; then
        break
      fi
      sleep 0.05
    done
    if ! grep -q 'Debug tile accept' "$log_file"; then
      kill "$log_pid" >/dev/null 2>&1 || true
      wait "$log_pid" 2>/dev/null || true
      echo "Prompt pan-animation tile seed failed for $label" >&2
      return 1
    fi
  fi
  local started_ms
  started_ms="$(date +%s%3N)"
  if [[ "$prompt_animation" == "1" ]]; then
    send_debug_pan_under_load 3
  else
    send_debug_pan_under_load 0
  fi
  local start_deadline=$((SECONDS + 1))
  while (( SECONDS <= start_deadline )); do
    if grep -q 'MAPPY_PAN_START' "$log_file"; then
      break
    fi
    sleep 0.01
  done
  local pan_start_line
  pan_start_line="$(grep -n 'MAPPY_PAN_START' "$log_file" | tail -1 | cut -d: -f1 || true)"
  if [[ -z "$pan_start_line" ]]; then
    echo "Pan fixture start marker was not observed for $label" >&2
    return 1
  fi

  if [[ "$prompt_animation" == "1" ]]; then
    # Action 4 starts one decoded visible tile after liftoff and closes the
    # fixture measurement in the same watch-side dispatch. Keeping both state
    # changes together avoids an emulator AppMessage delivery race.
    send_debug_pan_under_load 4
    local animation_start_deadline=$((SECONDS + 1))
    while (( SECONDS <= animation_start_deadline )); do
      if grep -q 'MAPPY_PAN_ANIMATION active=1' "$log_file"; then
        break
      fi
      sleep 0.01
    done
    if ! grep -q 'MAPPY_PAN_ANIMATION active=1' "$log_file"; then
      echo "Prompt post-pan tile animation did not start for $label" >&2
      return 1
    fi
    local prompt_deadline=$((SECONDS + 5))
    while (( SECONDS < prompt_deadline )); do
      if grep -q 'MAPPY_PERF' "$log_file"; then
        break
      fi
      sleep 0.05
    done
    sleep 0.1
    kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" 2>/dev/null || true

    local prompt_summary prompt_errors prompt_tile_advances prompt_draw_max
    prompt_summary="$(grep 'MAPPY_PERF' "$log_file" | tail -1 || true)"
    if [[ -z "$prompt_summary" ]]; then
      echo "Prompt pan-animation fixture did not finish: $(windows_path "$log_file")" >&2
      return 1
    fi
    prompt_errors="$(perf_summary_value "$prompt_summary" e)"
    prompt_tile_advances="$(perf_summary_value "$prompt_summary" l)"
    prompt_draw_max="$(perf_summary_pair_value "$prompt_summary" q max)"
    if [[ -z "$prompt_errors" || "$prompt_errors" != "0" ]]; then
      echo "Prompt pan-animation fixture reported errors for $label: $prompt_summary" >&2
      return 1
    fi
    if [[ -z "$prompt_tile_advances" ]] || (( prompt_tile_advances < 1 )); then
      echo "Prompt post-pan tile did not animate for $label: $prompt_summary" >&2
      return 1
    fi
    if [[ -z "$prompt_draw_max" ]] || (( prompt_draw_max > 100 )); then
      echo "Prompt post-pan fade draw exceeded 100 ms for $label: $prompt_summary" >&2
      return 1
    fi
    if grep -Eqi 'Tile flight expired|tile chunk reject|tile decode failed|inbox dropped' \
        "$log_file"; then
      echo "Prompt tile transfer error reported for $label: $(windows_path "$log_file")" >&2
      return 1
    fi

    printf '%s: %s\n' "$label" "$prompt_summary"
    return 0
  fi

  sleep 0.12
  local input_frame_ms host_input_started_ms host_input_frame_ms
  send_debug_pan_under_load 1
  host_input_started_ms="$(date +%s%3N)"
  local input_deadline=$((SECONDS + 1))
  while (( SECONDS <= input_deadline )); do
    if grep -q 'MAPPY_PAN_FRAME' "$log_file"; then
      break
    fi
    sleep 0.01
  done
  input_frame_ms="$(perf_summary_value \
      "$(grep 'MAPPY_PAN_FRAME' "$log_file" | tail -1 || true)" i)"
  host_input_frame_ms=$(($(date +%s%3N) - host_input_started_ms))

  local load_complete=0
  local fill_ms=0
  while (( $(date +%s%3N) - started_ms < 4800 )); do
    if tail -n "+$((pan_start_line + 1))" "$log_file" | grep -q 'MAPPY_GRID'; then
      fill_ms=$(($(date +%s%3N) - started_ms))
      load_complete=1
      break
    fi
    sleep 0.1
  done
  sleep 0.1
  send_debug_pan_under_load 2
  local deadline=$((SECONDS + 2))
  while (( SECONDS < deadline )); do
    if grep -q 'MAPPY_PERF' "$log_file"; then
      break
    fi
    sleep 0.1
  done
  sleep 0.2
  kill "$log_pid" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true

  local perf_summary
  perf_summary="$(grep 'MAPPY_PERF' "$log_file" | tail -1 || true)"
  if [[ -z "$perf_summary" ]]; then
    echo "Pan-under-load fixture did not finish: $(windows_path "$log_file")" >&2
    return 1
  fi

  local draws draw_max
  draws="$(perf_summary_value "$perf_summary" d)"
  draw_max="$(perf_summary_pair_value "$perf_summary" q max)"

  if [[ ! -s "$log_file" ]] ||
      ! grep -q 'MAPPY_PAN_FRAME' "$log_file"; then
    echo "Pan interaction assertion failed for $label: $perf_summary" >&2
    return 1
  fi
  if [[ -z "$input_frame_ms" ]] || (( input_frame_ms < 0 || input_frame_ms > 100 )); then
    echo "Pan latency exceeded 100 ms for $label: ${input_frame_ms} ms" >&2
    return 1
  fi
  if (( host_input_frame_ms > 100 )); then
    echo "Host-observed pan frame exceeded 100 ms for $label: ${host_input_frame_ms} ms" >&2
    return 1
  fi
  local draw_limit=50
  if [[ "$orientation" == "1" ]]; then
    draw_limit=100
  fi
  if [[ -z "$draw_max" ]] || (( draw_max > draw_limit )); then
    echo "Map draw exceeded ${draw_limit} ms for $label: $perf_summary" >&2
    return 1
  fi
  if (( load_complete != 1 || fill_ms > 5000 )); then
    echo "Cold tile load did not complete within 5 seconds for $label" >&2
    return 1
  fi
  local draw_limit_count=$((expected_tiles + 12))
  if (( animation != 0 )); then
    local tile_advances
    tile_advances="$(perf_summary_value "$perf_summary" l)"
    if [[ -z "$tile_advances" ]] || (( tile_advances < 1 )); then
      echo "Tile animation did not advance for $label: $perf_summary" >&2
      return 1
    fi
    draw_limit_count=$((expected_tiles + tile_advances + 4))
  fi
  if [[ -z "$draws" ]] || (( draws > draw_limit_count )); then
    echo "Tile redraw coalescing assertion failed for $label: $perf_summary" >&2
    return 1
  fi
  local high_entropy_bytes=$((width * height))
  if ! grep -Eq "Tile accept .*encoded=${high_entropy_bytes}([[:space:]]|$)" "$log_file"; then
    echo "No accepted high-entropy multi-chunk tile for $label" >&2
    return 1
  fi
  if grep -Eqi 'Tile flight expired|tile chunk reject|tile decode failed|inbox dropped' \
      "$log_file"; then
    echo "Tile transfer error reported for $label: $(windows_path "$log_file")" >&2
    return 1
  fi

  printf '%s (%d ms watch / %d ms host input, %d ms fill): %s\n' \
    "$label" "$input_frame_ms" "$host_input_frame_ms" "$fill_ms" \
    "$perf_summary"
}

run_pan_inertia_case() {
  local width="$1"
  local height="$2"
  local orientation="$3"
  local orientation_name="north"
  if [[ "$orientation" == "1" ]]; then
    orientation_name="facing"
  fi
  local label="${width}x${height}-${orientation_name}-inertia"
  local log_file="$OUT_DIR/pan-under-load-${label}.log"
  rm -f "$log_file"

  cd "$WATCH_DIR"
  PYTHONUNBUFFERED=1 pebble logs --emulator "$PLATFORM" >"$log_file" 2>&1 &
  local log_pid=$!
  sleep 1
  send_fixture_map_orientation "$orientation"
  sleep 0.15
  send_fixture_tile_animation 0
  sleep 0.15
  send_debug_compass_recenter 0
  sleep 0.5

  local started_ms
  started_ms="$(date +%s%3N)"
  send_debug_pan_under_load 5
  local start_deadline=$((SECONDS + 1))
  while (( SECONDS <= start_deadline )); do
    if grep -q 'MAPPY_PAN_INERTIA' "$log_file"; then
      break
    fi
    sleep 0.01
  done
  local inertia_marker start_line
  inertia_marker="$(grep 'MAPPY_PAN_INERTIA' "$log_file" | tail -1 || true)"
  start_line="$(grep -n 'MAPPY_PAN_INERTIA' "$log_file" | tail -1 | cut -d: -f1 || true)"
  if [[ -z "$start_line" || "$inertia_marker" != *"active=1"* ]]; then
    kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" 2>/dev/null || true
    echo "Pan inertia fixture did not start for $label: $inertia_marker" >&2
    return 1
  fi

  local summary_deadline=$((SECONDS + 2))
  while (( SECONDS < summary_deadline )); do
    if tail -n "+$start_line" "$log_file" | grep -q 'MAPPY_PERF'; then
      break
    fi
    sleep 0.02
  done
  local perf_summary inertia_summary rotated_summary summary_line input_frame
  perf_summary="$(tail -n "+$start_line" "$log_file" | grep 'MAPPY_PERF' | tail -1 || true)"
  inertia_summary="$(tail -n "+$start_line" "$log_file" | grep 'MAPPY_IPERF' | tail -1 || true)"
  rotated_summary="$(tail -n "+$start_line" "$log_file" | grep 'MAPPY_RPERF' | tail -1 || true)"
  summary_line="$(grep -n 'MAPPY_PERF' "$log_file" | tail -1 | cut -d: -f1 || true)"
  input_frame="$(tail -n "+$start_line" "$log_file" | grep 'MAPPY_PAN_FRAME' | head -1 || true)"
  if [[ -z "$perf_summary" || -z "$inertia_summary" ||
        -z "$rotated_summary" || -z "$summary_line" ]]; then
    kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" 2>/dev/null || true
    echo "Pan inertia fixture did not finish for $label: $(windows_path "$log_file")" >&2
    return 1
  fi

  if awk -v start="$start_line" -v finish="$summary_line" \
      'NR > start && NR < finish && (/Tile accept/ || /MAPPY_GRID/) { found = 1 }
       END { exit !found }' "$log_file"; then
    kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" 2>/dev/null || true
    echo "Tile decode churn occurred during coast for $label" >&2
    return 1
  fi

  local load_complete=0
  local fill_ms=0
  while (( $(date +%s%3N) - started_ms < 5000 )); do
    if awk -v start="$summary_line" \
        'NR > start && /MAPPY_GRID/ { found = 1 } END { exit !found }' \
        "$log_file"; then
      fill_ms=$(($(date +%s%3N) - started_ms))
      load_complete=1
      break
    fi
    sleep 0.05
  done
  sleep 0.1
  kill "$log_pid" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true

  local errors active_ticks changed_ticks coast_dx coast_dy coast_ms
  local draws draw_max tile_advances orientation_work rotated_pixels
  local input_frame_ms
  errors="$(perf_summary_value "$perf_summary" e)"
  active_ticks="$(perf_summary_value "$inertia_summary" a)"
  changed_ticks="$(perf_summary_value "$inertia_summary" c)"
  coast_dx="$(perf_summary_signed_value "$inertia_summary" x)"
  coast_dy="$(perf_summary_signed_value "$inertia_summary" y)"
  coast_ms="$(perf_summary_signed_value "$inertia_summary" ms)"
  draws="$(perf_summary_value "$perf_summary" d)"
  draw_max="$(perf_summary_pair_value "$perf_summary" q max)"
  tile_advances="$(perf_summary_value "$perf_summary" l)"
  orientation_work="$(perf_summary_value "$perf_summary" o)"
  rotated_pixels="$(perf_summary_value "$rotated_summary" p)"
  input_frame_ms="$(perf_summary_value "$input_frame" i)"

  if [[ -z "$errors" || "$errors" != "0" ]]; then
    echo "Pan inertia fixture reported errors for $label: $perf_summary" >&2
    return 1
  fi
  if [[ -z "$active_ticks" || -z "$changed_ticks" ]] ||
      (( active_ticks < 1 || changed_ticks < 1 || changed_ticks > 12 ||
         changed_ticks > active_ticks )); then
    echo "Pan inertia scheduler bounds failed for $label: $inertia_summary" >&2
    return 1
  fi
  if [[ -z "$draws" ]] || (( draws < 1 || draws > changed_ticks + 1 )); then
    echo "Pan inertia redraw coalescing failed for $label: $perf_summary" >&2
    return 1
  fi
  if [[ -z "$input_frame_ms" ]] ||
      (( input_frame_ms < 0 || input_frame_ms > 100 )); then
    echo "Pan inertia first frame exceeded 100 ms for $label: ${input_frame_ms} ms" >&2
    return 1
  fi
  if [[ -z "$draw_max" ]] || (( draw_max > 50 )); then
    echo "North-up inertia draw exceeded 50 ms for $label: $perf_summary" >&2
    return 1
  fi
  if [[ -z "$tile_advances" || "$tile_advances" != "0" ||
        -z "$orientation_work" || "$orientation_work" != "0" ||
        -z "$rotated_pixels" || "$rotated_pixels" != "0" ]]; then
    echo "Pan inertia performed tile/orientation animation work for $label: $perf_summary / $rotated_summary" >&2
    return 1
  fi
  if [[ -z "$coast_dx" || -z "$coast_dy" ]] ||
      (( coast_dx >= 0 || coast_dy >= 0 )); then
    echo "Pan inertia direction failed for $label: $inertia_summary" >&2
    return 1
  fi
  local abs_dx=$((-coast_dx))
  local abs_dy=$((-coast_dy))
  local coast_distance
  if (( abs_dx >= abs_dy )); then
    coast_distance=$((abs_dx + abs_dy / 2))
  else
    coast_distance=$((abs_dy + abs_dx / 2))
  fi
  if (( coast_distance < 40 || coast_distance > 72 )); then
    echo "Pan inertia displacement was outside 40..72 px for $label: $inertia_summary" >&2
    return 1
  fi
  if (( load_complete != 1 || fill_ms > 5000 )); then
    echo "Settled inertia grid did not complete within 5 seconds for $label" >&2
    return 1
  fi
  if ! awk -v start="$summary_line" \
      'NR > start && /Tile accept / { found = 1 } END { exit !found }' \
      "$log_file"; then
    echo "Settled inertia did not load a new tile for $label" >&2
    return 1
  fi
  if grep -Eqi 'Tile flight expired|tile chunk reject|tile decode failed|inbox dropped' \
      "$log_file"; then
    echo "Tile transfer error reported for $label: $(windows_path "$log_file")" >&2
    return 1
  fi

  printf '%s (%d ms first frame, %d ms coast, %d ms fill, %d px): %s / %s\n' \
    "$label" "$input_frame_ms" "$coast_ms" "$fill_ms" "$coast_distance" \
    "$perf_summary" "$inertia_summary"
}

run_pan_inertia_cancel_case() {
  local action="$1"
  local cancellation="$2"
  local resume_grace_ms=100
  local label="108x126-north-cancel-${cancellation}"
  local log_file="$OUT_DIR/pan-under-load-${label}.log"
  rm -f "$log_file"

  cd "$WATCH_DIR"
  local log_pid=""
  local log_attempt
  for log_attempt in 1 2 3; do
    : >"$log_file"
    PYTHONUNBUFFERED=1 pebble logs --emulator "$PLATFORM" >"$log_file" 2>&1 &
    log_pid=$!
    sleep 1
    if kill -0 "$log_pid" >/dev/null 2>&1; then
      break
    fi
    wait "$log_pid" 2>/dev/null || true
    log_pid=""
  done
  if [[ -z "$log_pid" ]]; then
    echo "Pebble log capture did not start for $label" >&2
    return 1
  fi
  send_fixture_map_orientation 0
  sleep 0.15
  send_fixture_tile_animation 0
  sleep 0.15
  send_debug_compass_recenter 0
  sleep 0.5

  local started_ms
  started_ms="$(date +%s%3N)"
  send_debug_pan_under_load "$action"
  local cancel_deadline=$((SECONDS + 1))
  while (( SECONDS <= cancel_deadline )); do
    if grep -q "MAPPY_PAN_CANCEL kind=${action}" "$log_file"; then
      break
    fi
    sleep 0.01
  done
  local marker marker_line lifecycle_ms
  marker="$(grep "MAPPY_PAN_CANCEL kind=${action}" "$log_file" | tail -1 || true)"
  marker_line="$(grep -n "MAPPY_PAN_CANCEL kind=${action}" "$log_file" |
      tail -1 | cut -d: -f1 || true)"
  lifecycle_ms=$(($(date +%s%3N) - started_ms))
  if [[ -z "$marker" || -z "$marker_line" ]]; then
    kill "$log_pid" >/dev/null 2>&1 || true
    wait "$log_pid" 2>/dev/null || true
    echo "Pan inertia $cancellation cancellation marker was not observed" >&2
    return 1
  fi

  local summary_deadline=$((SECONDS + 2))
  while (( SECONDS < summary_deadline )); do
    if tail -n "+$marker_line" "$log_file" | grep -q 'MAPPY_PERF'; then
      break
    fi
    sleep 0.02
  done
  local perf_summary inertia_summary
  perf_summary="$(tail -n "+$marker_line" "$log_file" |
      grep 'MAPPY_PERF' | tail -1 || true)"
  inertia_summary="$(tail -n "+$marker_line" "$log_file" |
      grep 'MAPPY_IPERF' | tail -1 || true)"
  sleep 0.1
  kill "$log_pid" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true

  if [[ -z "$perf_summary" || -z "$inertia_summary" ]]; then
    echo "Pan inertia $cancellation cancellation summary was not observed: $(windows_path "$log_file")" >&2
    return 1
  fi
  local started failures active paused grace touch errors
  local active_ticks changed_ticks
  started="$(perf_summary_value "$marker" started)"
  failures="$(perf_summary_value "$marker" f)"
  active="$(perf_summary_value "$marker" active)"
  paused="$(perf_summary_value "$marker" paused)"
  grace="$(perf_summary_value "$marker" grace)"
  touch="$(perf_summary_value "$marker" touch)"
  errors="$(perf_summary_value "$perf_summary" e)"
  active_ticks="$(perf_summary_value "$inertia_summary" a)"
  changed_ticks="$(perf_summary_value "$inertia_summary" c)"

  if [[ "$started" != "1" || "$failures" != "0" || "$active" != "0" ||
        "$paused" != "0" || "$grace" != "0" || "$touch" != "0" ]]; then
    echo "Pan inertia $cancellation cancellation lifecycle failed: $marker" >&2
    return 1
  fi
  if [[ -z "$errors" || "$errors" != "0" ]]; then
    echo "Pan inertia $cancellation cancellation reported errors: $perf_summary" >&2
    return 1
  fi
  if [[ "$active_ticks" != "0" || "$changed_ticks" != "0" ]]; then
    echo "Pan inertia $cancellation advanced after synchronous cancellation: $inertia_summary" >&2
    return 1
  fi
  if (( lifecycle_ms < resume_grace_ms || lifecycle_ms > 1000 )); then
    echo "Pan inertia $cancellation grace lifecycle took ${lifecycle_ms} ms" >&2
    return 1
  fi
  if grep -Eqi 'Tile flight expired|tile chunk reject|tile decode failed|inbox dropped' \
      "$log_file"; then
    echo "Tile transfer error during $cancellation cancellation: $(windows_path "$log_file")" >&2
    return 1
  fi

  printf '%s (%d ms lifecycle): %s / %s\n' \
    "$label" "$lifecycle_ms" "$marker" "$perf_summary"
}

test_pan_under_load() {
  require_pebble
  local prompt_only="${1:-}"
  if [[ -n "$prompt_only" && "$prompt_only" != "prompt" ]]; then
    echo "test-pan-under-load argument must be 'prompt' when supplied" >&2
    return 2
  fi
  if pgrep -x qemu-pebble >/dev/null 2>&1; then
    echo "Pebble emulator is already running; retry test-pan-under-load after its owner finishes." >&2
    return 75
  fi
  set_phone_mode fixture
  export MAPPY_FIXTURE_ROUTE_POINT_COUNT=3
  export MAPPY_FIXTURE_TILE_ANIMATION_MODE=0
  export MAPPY_FIXTURE_TILE_DELAY_MS=0
  export MAPPY_FIXTURE_TILE_STAGGER_MS=0
  export MAPPY_FIXTURE_TILE_CHUNK_BYTES=3072
  export MAPPY_FIXTURE_TILE_HIGH_ENTROPY=1
  export MAPPY_FIXTURE_INJECT_STALE_TILE_FIRST=1
  export MAPPY_FIXTURE_TX_SUCCESS_DELAY_MS=5
  mkdir -p "$OUT_DIR"
  trap 'pebble kill >/dev/null 2>&1 || true' RETURN

  if [[ "$prompt_only" == "prompt" ]]; then
    export MAPPY_FIXTURE_TILE_WIDTH=108
    export MAPPY_FIXTURE_TILE_HEIGHT=126
    pebble kill >/dev/null 2>&1 || true
    install_app_with_recovery
    sleep 6
    run_pan_under_load_case 108 126 1 1 1
    pebble kill >/dev/null 2>&1 || true
    trap - RETURN
    return
  fi

  local geometry width height orientation
  for geometry in 54:63 72:84 108:126; do
    width="${geometry%%:*}"
    height="${geometry##*:}"
    export MAPPY_FIXTURE_TILE_WIDTH="$width"
    export MAPPY_FIXTURE_TILE_HEIGHT="$height"
    for orientation in 0 1; do
      # Keep each orientation's normal-pan and inertia cases under the same
      # load, but reset the in-memory cache before switching modes so prior
      # cases cannot exhaust tile storage and strand the settlement check.
      pebble kill >/dev/null 2>&1 || true
      install_app_with_recovery
      sleep 6
      run_pan_inertia_case "$width" "$height" "$orientation"
      run_pan_under_load_case "$width" "$height" "$orientation" 0
    done
  done

  # Exercise the normal tile animation path with immediate responses. Tiles
  # requested after touch liftoff must animate without a grace-period delay.
  export MAPPY_FIXTURE_TILE_DELAY_MS=0
  pebble kill >/dev/null 2>&1 || true
  install_app_with_recovery
  sleep 6
  run_pan_under_load_case 108 126 1 1 1
  run_pan_under_load_case 108 126 1 1
  run_pan_inertia_cancel_case 6 new-touch
  run_pan_inertia_cancel_case 7 zoom
  run_pan_inertia_cancel_case 8 recenter
  run_pan_inertia_cancel_case 9 menu
  pebble kill >/dev/null 2>&1 || true
  trap - RETURN
  printf 'Pan-under-load logs: %s\n' \
    "$(windows_path "$OUT_DIR/pan-under-load-*.log")"
}

test_rapid_zoom_reversal() {
  require_pebble
  if pgrep -x qemu-pebble >/dev/null 2>&1; then
    echo "Pebble emulator is already running; retry test-rapid-zoom-reversal after its owner finishes." >&2
    return 75
  fi

  set_phone_mode fixture
  export MAPPY_FIXTURE_ROUTE_POINT_COUNT=3
  export MAPPY_FIXTURE_TILE_ANIMATION_MODE=0
  export MAPPY_FIXTURE_TILE_WIDTH=72
  export MAPPY_FIXTURE_TILE_HEIGHT=84
  export MAPPY_FIXTURE_TILE_DELAY_MS=400
  export MAPPY_FIXTURE_TILE_STAGGER_MS=0
  export MAPPY_FIXTURE_TILE_CHUNK_BYTES=3072
  export MAPPY_FIXTURE_TILE_HIGH_ENTROPY=1
  export MAPPY_FIXTURE_INJECT_STALE_TILE_FIRST=1
  export MAPPY_FIXTURE_TX_SUCCESS_DELAY_MS=5

  mkdir -p "$OUT_DIR"
  local log_file="$OUT_DIR/rapid-zoom-reversal.log"
  local log_pid=""
  rm -f "$log_file"
  trap 'if [[ -n "${log_pid:-}" ]]; then kill "$log_pid" >/dev/null 2>&1 || true; wait "$log_pid" 2>/dev/null || true; fi; pebble kill >/dev/null 2>&1 || true' RETURN

  install_app_with_recovery
  cd "$WATCH_DIR"
  PYTHONUNBUFFERED=1 pebble logs --emulator "$PLATFORM" >"$log_file" 2>&1 &
  log_pid=$!
  sleep 1

  # Establish one complete, north-up source grid before beginning the timed
  # reversal. The response delay keeps this marker observable after logs attach.
  local baseline_start_line
  baseline_start_line="$(( $(wc -l < "$log_file") + 1 ))"
  send_fixture_map_orientation 0
  sleep 0.15
  send_fixture_tile_animation 0
  sleep 0.15
  send_debug_compass_recenter 0

  local baseline_grid_line=""
  local baseline_deadline=$((SECONDS + 15))
  while (( SECONDS < baseline_deadline )); do
    baseline_grid_line="$(awk -v start="$baseline_start_line" \
      'NR >= start && /MAPPY_GRID/ { print NR; exit }' "$log_file")"
    if [[ -n "$baseline_grid_line" ]]; then
      break
    fi
    sleep 0.05
  done
  if [[ -z "$baseline_grid_line" ]]; then
    echo "Rapid zoom reversal did not establish its source grid: $(windows_path "$log_file")" >&2
    return 1
  fi

  local source_zoom
  source_zoom="$(sed -nE \
    "${baseline_start_line},${baseline_grid_line}s/.*Tile accept .* z=(-?[0-9]+) encoded=.*/\\1/p" \
    "$log_file" | tail -n 1)"
  if [[ ! "$source_zoom" =~ ^-?[0-9]+$ ]]; then
    echo "Rapid zoom reversal could not determine its source zoom: $(windows_path "$log_file")" >&2
    return 1
  fi

  local max_zoom
  max_zoom="$(sed -nE \
    's/^[[:space:]]*#define[[:space:]]+MAX_MAP_ZOOM[[:space:]]+([0-9]+).*/\1/p' \
    "$WATCH_DIR/src/c/mappy.h" | head -n 1)"
  if [[ ! "$max_zoom" =~ ^[0-9]+$ ]]; then
    echo "Rapid zoom reversal could not determine MAX_MAP_ZOOM" >&2
    return 1
  fi

  local target_zoom=$((source_zoom + 1))
  local first_button="up"
  local reverse_button="down"
  if (( source_zoom >= max_zoom )); then
    target_zoom=$((source_zoom - 1))
    first_button="down"
    reverse_button="up"
  fi

  local zoom_start_line
  zoom_start_line="$(( $(wc -l < "$log_file") + 1 ))"
  send_button click "$first_button"

  # Arena pressure at B must evict a retained A tile before B completes. Record
  # that exact coordinate so the reversal proves it was requested and accepted
  # again, rather than merely relying on an already-cached source grid.
  local eviction_record=""
  local eviction_deadline=$((SECONDS + 10))
  while (( SECONDS < eviction_deadline )); do
    eviction_record="$(awk -v start="$zoom_start_line" \
      -v needle="z=${source_zoom} bytes=" \
      'NR >= start && index($0, "Tile storage evict x=") && index($0, needle) { print NR "|" $0; exit }' \
      "$log_file")"
    if [[ -n "$eviction_record" ]]; then
      break
    fi
    sleep 0.02
  done
  if [[ -z "$eviction_record" ]]; then
    echo "Rapid zoom reversal did not evict a source fallback tile under arena pressure: $(windows_path "$log_file")" >&2
    return 1
  fi

  local eviction_line_number="${eviction_record%%|*}"
  local eviction_line="${eviction_record#*|}"
  local evicted_x evicted_y
  evicted_x="$(sed -nE \
    's/.*Tile storage evict x=(-?[0-9]+) y=(-?[0-9]+) z=-?[0-9]+.*/\1/p' \
    <<<"$eviction_line")"
  evicted_y="$(sed -nE \
    's/.*Tile storage evict x=-?[0-9]+ y=(-?[0-9]+) z=-?[0-9]+.*/\1/p' \
    <<<"$eviction_line")"
  if [[ ! "$evicted_x" =~ ^-?[0-9]+$ || ! "$evicted_y" =~ ^-?[0-9]+$ ]]; then
    echo "Rapid zoom reversal could not parse the evicted source coordinate: $eviction_line" >&2
    return 1
  fi

  local target_accept_line=""
  local target_accept_deadline_ms=$(( $(date +%s%3N) + 250 ))
  while (( $(date +%s%3N) < target_accept_deadline_ms )); do
    target_accept_line="$(awk -v start="$((eviction_line_number + 1))" \
      -v needle="z=${target_zoom} encoded=" \
      'NR >= start && index($0, "Tile accept x=") && index($0, needle) { print NR; exit }' \
      "$log_file")"
    if [[ -n "$target_accept_line" ]]; then
      break
    fi
    sleep 0.01
  done
  if [[ -z "$target_accept_line" ]]; then
    echo "Rapid zoom reversal saw a source eviction without the corresponding target acceptance: $(windows_path "$log_file")" >&2
    return 1
  fi
  if awk -v start="$zoom_start_line" \
      'NR >= start && /MAPPY_GRID/ { found = 1 } END { exit !found }' \
      "$log_file"; then
    echo "Target grid completed before the rapid reversal; delayed-load coverage was not exercised" >&2
    return 1
  fi

  local reversal_start_line
  reversal_start_line="$(( $(wc -l < "$log_file") + 1 ))"
  local reversal_started_ms
  reversal_started_ms="$(date +%s%3N)"
  send_button click "$reverse_button"

  local refetch_line=""
  local completion_grid_line=""
  local completion_ms=-1
  local now_ms elapsed_ms
  while :; do
    now_ms="$(date +%s%3N)"
    elapsed_ms=$((now_ms - reversal_started_ms))
    refetch_line="$(awk -v start="$reversal_start_line" \
      -v needle="Tile accept x=${evicted_x} y=${evicted_y} z=${source_zoom} encoded=" \
      'NR >= start && index($0, needle) { print NR; exit }' "$log_file")"
    if [[ -n "$refetch_line" ]]; then
      completion_grid_line="$(awk -v start="$((refetch_line + 1))" \
        'NR >= start && /MAPPY_GRID/ { print NR; exit }' "$log_file")"
    fi
    if [[ -n "$completion_grid_line" && $elapsed_ms -le 5000 ]]; then
      completion_ms="$elapsed_ms"
      break
    fi
    if (( elapsed_ms >= 5000 )); then
      break
    fi
    sleep 0.02
  done

  sleep 0.2
  kill "$log_pid" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true
  log_pid=""

  if [[ -z "$refetch_line" ]]; then
    echo "Evicted source tile (${evicted_x},${evicted_y},z${source_zoom}) was not accepted after reversal: $(windows_path "$log_file")" >&2
    return 1
  fi
  if [[ -z "$completion_grid_line" || $completion_ms -lt 0 ]]; then
    echo "Source grid did not complete strictly within 5 seconds of reversal: $(windows_path "$log_file")" >&2
    return 1
  fi
  if ! grep -Eq 'Tile accept .*encoded=6048([[:space:]]|$)' "$log_file"; then
    echo "Rapid zoom reversal did not accept a genuine 72x84 multi-chunk tile" >&2
    return 1
  fi
  local health_failure_pattern='Tile flight expired|tile chunk reject|tile decode failed|inbox dropped|Outbox failed cmd=202'
  health_failure_pattern+='|(^|[^[:alnum:]])fault([^[:alnum:]]|$)|faulted|hardfault|appfault|crash(ed|ing)?'
  if grep -Eqi "$health_failure_pattern" "$log_file"; then
    echo "Tile transfer error reported during rapid zoom reversal: $(windows_path "$log_file")" >&2
    return 1
  fi

  pebble kill >/dev/null 2>&1 || true
  trap - RETURN
  printf 'Rapid zoom reversal z%d -> z%d -> z%d: refetched (%s,%s) and completed in %d ms\nLog: %s\n' \
    "$source_zoom" "$target_zoom" "$source_zoom" "$evicted_x" "$evicted_y" \
    "$completion_ms" "$(windows_path "$log_file")"
}

test_motion_reacquire() {
  require_pebble
  if pgrep -x qemu-pebble >/dev/null 2>&1; then
    echo "Pebble emulator is already running; retry test-motion-reacquire after its owner finishes." >&2
    return 75
  fi
  set_phone_mode fixture
  mkdir -p "$OUT_DIR"
  local log_file="$OUT_DIR/motion-reacquire.log"
  rm -f "$log_file"

  # This command owns only an emulator that it starts itself. Do not use the
  # wipe-and-retry path because a concurrent task may acquire the emulator.
  trap 'pebble kill >/dev/null 2>&1 || true' RETURN
  install_app
  sleep 6
  cd "$WATCH_DIR"
  PYTHONUNBUFFERED=1 pebble logs --emulator "$PLATFORM" >"$log_file" 2>&1 &
  local log_pid=$!
  trap 'kill "$log_pid" >/dev/null 2>&1 || true; pebble kill >/dev/null 2>&1 || true' RETURN
  sleep 1

  send_debug_facing 0
  sleep 1
  if ! grep -Fq 'Debug compass heading=0' "$log_file"; then
    echo "Pebble emulator log transport did not produce the fixture probe; retry after other emulator work finishes." >&2
    return 75
  fi
  send_button click select
  sleep 0.2
  send_button click down
  sleep 0.2
  send_button click select
  sleep 0.2
  send_button click down
  sleep 0.2
  send_button click select
  sleep 0.3
  send_button click select
  sleep 0.2
  send_button click select
  sleep 0.2
  send_button click select
  sleep 5

  send_debug_motion stationary-raise
  # emu-accel queues samples into QEMU and returns before 25 Hz playback ends.
  # Let the entire 55-sample negative trace finish before evaluating it.
  sleep 2.5
  if grep -Fq 'Motion state=looking' "$log_file"; then
    echo "Stationary raise incorrectly triggered watch-look detection" >&2
    return 1
  fi

  # Toggle out of face-forward mode to unsubscribe/reset the classifier, then
  # restore the active route context for an independent positive trace.
  cd "$WATCH_DIR"
  pebble send-app-message --emulator "$PLATFORM" --app-uuid "$(app_uuid)" \
    --int 50=205 60=0
  sleep 0.3
  send_debug_facing 0
  sleep 0.5

  send_debug_motion walking-to-look &
  local motion_pid=$!
  local look_ready=0
  for _ in $(seq 1 120); do
    if grep -Fq 'Motion state=looking' "$log_file"; then
      look_ready=1
      break
    fi
    sleep 0.05
  done
  if (( look_ready == 0 )); then
    wait "$motion_pid"
    echo "Walking trace did not produce watch-look detection; see $(windows_path "$log_file")" >&2
    return 1
  fi
  send_debug_compass 180
  wait "$motion_pid"
  sleep 1

  kill "$log_pid" >/dev/null 2>&1 || true
  wait "$log_pid" 2>/dev/null || true
  trap - RETURN

  local look_count
  look_count="$(grep -Fc 'Motion state=looking' "$log_file" || true)"
  if [[ "$look_count" != "1" ]]; then
    echo "Expected one watch-look event, found $look_count; see $(windows_path "$log_file")" >&2
    pebble kill >/dev/null 2>&1 || true
    return 1
  fi
  if ! grep -Fq 'Motion state=walking' "$log_file" ||
      ! grep -Fq 'Bearing reacquire reason=watch_look' "$log_file"; then
    echo "Motion state transition or watch-look reacquisition was not logged; see $(windows_path "$log_file")" >&2
    pebble kill >/dev/null 2>&1 || true
    return 1
  fi

  local summary steps
  summary="$(grep 'MAPPY_PERF' "$log_file" | tail -n 1)"
  steps="$(perf_summary_value "$summary" b)"
  if [[ -z "$steps" ]] || (( steps < 2 || steps > 8 )); then
    echo "Fast bearing animation did not complete in 2..8 ticks: $summary" >&2
    pebble kill >/dev/null 2>&1 || true
    return 1
  fi

  capture_screenshot motion-reacquire.png
  printf 'Motion: look_events=%s bearing_ticks=%s\nLog: %s\n' \
    "$look_count" "$steps" "$(windows_path "$log_file")"
  pebble kill >/dev/null 2>&1 || true
}

main() {
  local command="${1:-}"
  if [[ -z "$command" || "$command" == "-h" || "$command" == "--help" ]]; then
    usage
    exit 0
  fi
  shift

  case "$command" in
    build)
      build_app
      ;;
    doctor)
      doctor
      ;;
    test-tooling)
      test_tooling
      ;;
    test-protocol)
      test_protocol
      ;;
    test-motion-host)
      test_motion_host
      ;;
    test-navigation-feedback-host)
      test_navigation_feedback_host
      ;;
    test-pan-inertia-host)
      test_pan_inertia_host
      ;;
    test-tile-cache-host)
      test_tile_cache_host
      ;;
    test-tile-scheduler-host)
      test_tile_scheduler_host
      ;;
    test-face-forward-render-host|test-render-host)
      test_face_forward_render_host
      ;;
    test-face-forward-angles)
      test_face_forward_angles
      ;;
    test-render-performance)
      test_render_performance
      ;;
    test-pan-under-load)
      test_pan_under_load "$@"
      ;;
    test-rapid-zoom-reversal)
      test_rapid_zoom_reversal
      ;;
    test-motion-reacquire)
      test_motion_reacquire
      ;;
    build-fixture)
      set_phone_mode fixture
      build_app
      ;;
    build-real-fixture)
      set_phone_mode real-fixture
      build_app
      ;;
    build-fixture-animation)
      set_animation_fixture_defaults
      build_app
      ;;
    build-phone)
      set_phone_mode phone
      build_app
      ;;
    install)
      install_app
      ;;
    install-fixture)
      set_phone_mode fixture
      install_app
      ;;
    install-real-fixture)
      set_phone_mode real-fixture
      install_app
      ;;
    install-fixture-animation)
      set_animation_fixture_defaults
      install_app
      ;;
    install-phone)
      set_phone_mode phone
      install_app
      ;;
    wipe)
      wipe_emulator
      ;;
    screenshot)
      capture_screenshot "$@"
      ;;
    capture)
      capture_after_install
      ;;
    capture-fixture)
      set_phone_mode fixture
      if [[ -z "${PEBBLE_CAPTURE_DELAY_SECONDS:-}" ]]; then
        CAPTURE_DELAY_SECONDS=6
      fi
      capture_after_install
      ;;
    capture-real-fixture)
      set_phone_mode real-fixture
      if [[ -z "${PEBBLE_CAPTURE_DELAY_SECONDS:-}" ]]; then
        CAPTURE_DELAY_SECONDS=6
      fi
      capture_after_install
      ;;
    capture-fixture-animation)
      set_animation_fixture_defaults
      capture_after_install
      ;;
    record-fixture-animation)
      record_fixture_animation "$@"
      ;;
    capture-phone)
      set_phone_mode phone
      capture_after_install
      ;;
    smoke-fixture)
      smoke_fixture
      ;;
    generate-real-fixture)
      generate_real_fixture "$@"
      ;;
    debug-compass)
      send_debug_compass "$@"
      ;;
    debug-facing)
      send_debug_facing "$@"
      ;;
    debug-manual-browse)
      send_debug_compass_manual_browse "$@"
      ;;
    debug-location-position)
      send_debug_location_position "$@"
      ;;
    debug-recenter)
      send_debug_compass_recenter "$@"
      ;;
    debug-map-settings)
      send_debug_map_settings "$@"
      ;;
    debug-tile)
      send_debug_tile "$@"
      ;;
    debug-route-progress)
      send_debug_route_progress "$@"
      ;;
    debug-motion)
      send_debug_motion "$@"
      ;;
    button)
      send_button "$@"
      ;;
    kill)
      require_pebble
      pebble kill
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
