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
  test-tile-cache-host     Run bounded tile codec and arena host tests.
  test-render-performance  Run fixture bearing and mixed-animation assertions.
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
  test_tile_cache_host
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

test_render_performance() {
  require_pebble
  set_phone_mode fixture
  export MAPPY_FIXTURE_ROUTE_POINT_COUNT=128
  export MAPPY_FIXTURE_TILE_ANIMATION_MODE=1
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

  send_debug_compass_mixed 200
  sleep 3

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
  if (( ${#summaries[@]} < 7 )); then
    echo "Expected at least seven MAPPY_PERF summaries; see $(windows_path "$log_file")" >&2
    return 1
  fi
  local isolated="${summaries[${#summaries[@]}-4]}"
  local mixed="${summaries[${#summaries[@]}-3]}"
  local manual="${summaries[${#summaries[@]}-2]}"
  local recentered="${summaries[${#summaries[@]}-1]}"
  local isolated_draws isolated_steps isolated_projections
  local mixed_multi mixed_ticks mixed_draws mixed_gps mixed_tiles mixed_menu
  local mixed_clipped mixed_errors
  local manual_ticks manual_draws manual_steps manual_advances manual_browse
  local manual_map_errors manual_projections manual_orientation_work manual_errors
  local recentered_ticks recentered_steps recentered_browse
  local recentered_orientation_work recentered_errors
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

  if [[ -z "$manual_ticks" || -z "$manual_draws" || -z "$manual_steps" ||
        -z "$manual_advances" || -z "$manual_browse" ]] ||
      (( manual_ticks < 2 || manual_draws != manual_steps ||
         manual_advances != manual_steps || manual_browse != manual_steps )); then
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
      (( recentered_ticks < 2 || recentered_steps != recentered_ticks )); then
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

  printf 'Isolated: %s\nMixed: %s\nManual browse: %s\nRecentered: %s\nPerformance log: %s\n' \
    "$isolated" "$mixed" "$manual" "$recentered" \
    "$(windows_path "$log_file")"
  pebble kill >/dev/null 2>&1 || true
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
    test-tile-cache-host)
      test_tile_cache_host
      ;;
    test-render-performance)
      test_render_performance
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
