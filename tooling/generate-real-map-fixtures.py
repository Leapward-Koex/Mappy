#!/usr/bin/env python3
"""Generate local real-map Pebble watch fixtures.

This is a development-only tool. It reads a Google API key from the environment,
the ignored root .env.local file, or the Android local.properties file, fetches
Google Map Tiles/Routes data, then writes derived watch-protocol fixture
payloads. The generated fixture does not contain the API key or provider session
token.
"""

from __future__ import annotations

import argparse
import io
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from PIL import Image


KEY_CMD = 50
KEY_IS_COLOR = 54
KEY_BUTTON_ID = 60
KEY_WORLD_X = 63
KEY_WORLD_Y = 64
KEY_TILE_ZOOM = 65
KEY_REQUEST_ID = 70
CMD_INIT = 101
CMD_ERROR_STATE = 102
CMD_PHONE_READY = 104
CMD_GPS = 201
CMD_TILE_REQUEST = 202
CMD_TILE = 203
CMD_DESTINATIONS = 301
CMD_ROUTE_REQUEST = 302
CMD_ROUTE_POINTS = 303
CMD_ROUTE_CLEAR = 304
CMD_NAV_STEPS = 305
CMD_THEME = 401
CMD_TRAVEL_MODE = 402
CMD_UNITS = 403
CMD_BACKLIGHT = 404
CMD_TILE_ANIMATION = 206

ROUTE_WORLD_ZOOM = 16
SOURCE_TILE_SIZE = 256
WATCH_TILE_WIDTH = 54
WATCH_TILE_HEIGHT = 63
WATCH_TILE_PIXELS = WATCH_TILE_WIDTH * WATCH_TILE_HEIGHT
EMERY_WIDTH = 200
EMERY_HEIGHT = 228
MAX_ROUTE_POINTS = 128
MAX_NAV_STEPS = 255
MAX_WATCH_TEXT_BYTES = 47
MIN_WEB_MERCATOR_LAT = -85.05112878
MAX_WEB_MERCATOR_LAT = 85.05112878

DAY_PALETTE = [
    (250, 251, 245),
    (232, 238, 232),
    (209, 226, 207),
    (184, 214, 194),
    (246, 241, 219),
    (230, 214, 172),
    (255, 255, 255),
    (208, 222, 226),
    (173, 205, 222),
    (118, 170, 206),
    (203, 206, 202),
    (160, 166, 162),
    (99, 111, 107),
    (66, 74, 72),
    (218, 96, 81),
    (25, 112, 109),
]

NIGHT_PALETTE = [
    (22, 28, 34),
    (32, 42, 51),
    (42, 55, 65),
    (55, 70, 80),
    (62, 78, 71),
    (72, 91, 79),
    (86, 103, 86),
    (93, 101, 110),
    (105, 116, 124),
    (123, 130, 135),
    (145, 136, 105),
    (167, 148, 103),
    (190, 166, 111),
    (98, 149, 171),
    (202, 103, 91),
    (228, 232, 220),
]

DEFAULT_ORIGIN = (51.50740, -0.12780)
DEFAULT_DESTINATION = (51.50790, -0.12820)
DEFAULT_DESTINATION_LABEL = "Example Destination"
DEFAULT_DESTINATION_ADDRESS = "Westminster, London"


class FixtureError(RuntimeError):
    pass


def repo_root() -> Path:
    return Path(__file__).resolve().parents[1]


def read_local_properties(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def read_dotenv(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        if stripped.startswith("export "):
            stripped = stripped.removeprefix("export ").lstrip()
        key, value = stripped.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key.strip()] = value
    return values


def load_api_key(explicit: str | None, env_file: Path, local_properties: Path) -> str:
    if explicit:
        return explicit.strip()
    for env_name in ("GOOGLE_MAPS_API_KEY", "MAPPY_DEV_GOOGLE_API_KEY"):
        value = os.environ.get(env_name, "").strip()
        if value:
            return value
    value = read_dotenv(env_file).get("MAPPY_DEV_GOOGLE_API_KEY", "").strip()
    if value:
        return value
    value = read_local_properties(local_properties).get("mappy.devGoogleApiKey", "").strip()
    if value:
        return value
    raise FixtureError(
        "No API key found. Set MAPPY_DEV_GOOGLE_API_KEY, configure it in "
        f"{env_file}, or configure mappy.devGoogleApiKey in {local_properties}."
    )


def mask_key(text: str, key: str) -> str:
    text = text.replace(key, "[redacted-google-key]")
    return re.sub(r"AIza[0-9A-Za-z_-]+", "[redacted-google-key]", text)


def find_keytool() -> str | None:
    candidates = [
        shutil.which("keytool"),
        os.environ.get("JAVA_HOME") and str(Path(os.environ["JAVA_HOME"]) / "bin" / "keytool.exe"),
        r"C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe",
        r"C:\Program Files\Android\Android Studio\jre\bin\keytool.exe",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    return None


def default_debug_keystore() -> Path:
    return Path.home() / ".android" / "debug.keystore"


def debug_cert_sha1(debug_keystore: Path) -> str | None:
    keytool = find_keytool()
    if not keytool or not debug_keystore.exists():
        return None
    result = subprocess.run(
        [
            keytool,
            "-list",
            "-v",
            "-keystore",
            str(debug_keystore),
            "-alias",
            "androiddebugkey",
            "-storepass",
            "android",
            "-keypass",
            "android",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    text = result.stdout + "\n" + result.stderr
    match = re.search(r"SHA1:\s*([0-9A-Fa-f:]{40,59})", text)
    if not match:
        return None
    return match.group(1).replace(":", "").upper()


def http_json(
    url: str,
    *,
    key: str,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: int = 30,
) -> Any:
    data = http_bytes(url, key=key, method=method, headers=headers, body=body, timeout=timeout)
    return json.loads(data.decode("utf-8"))


def http_bytes(
    url: str,
    *,
    key: str,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: int = 30,
) -> bytes:
    request = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise FixtureError(f"HTTP {exc.code}: {mask_key(detail[:600], key)}") from exc
    except urllib.error.URLError as exc:
        raise FixtureError(f"Network request failed: {exc.reason}") from exc


def android_headers(package_name: str, cert_sha1: str | None) -> dict[str, str]:
    headers = {"X-Android-Package": package_name}
    if cert_sha1:
        headers["X-Android-Cert"] = cert_sha1
    return headers


def create_tile_session(key: str, package_name: str, cert_sha1: str | None) -> dict[str, Any]:
    body = json.dumps(
        {
            "mapType": "roadmap",
            "language": "en-US",
            "region": "US",
            "scale": "scaleFactor1x",
            "highDpi": False,
            "imageFormat": "png",
        }
    ).encode("utf-8")
    url = "https://tile.googleapis.com/v1/createSession?key=" + urllib.parse.quote(key)
    response = http_json(
        url,
        key=key,
        method="POST",
        headers=android_headers(package_name, cert_sha1)
        | {"Content-Type": "application/json; charset=utf-8"},
        body=body,
    )
    if response.get("tileWidth") != 256 or response.get("tileHeight") != 256 or not response.get("session"):
        raise FixtureError("Unexpected Map Tiles session response.")
    return response


def fetch_source_tile(
    key: str,
    package_name: str,
    cert_sha1: str | None,
    session_token: str,
    zoom: int,
    tile_x: int,
    tile_y: int,
) -> Image.Image:
    url = (
        f"https://tile.googleapis.com/v1/2dtiles/{zoom}/{tile_x}/{tile_y}"
        f"?session={urllib.parse.quote(session_token)}&key={urllib.parse.quote(key)}"
    )
    data = http_bytes(url, key=key, headers=android_headers(package_name, cert_sha1))
    return Image.open(io.BytesIO(data)).convert("RGB")


def compute_route(
    key: str,
    package_name: str,
    cert_sha1: str | None,
    origin: tuple[float, float],
    destination: tuple[float, float],
    travel_mode: str,
) -> dict[str, Any]:
    body = json.dumps(
        {
            "origin": {"location": {"latLng": {"latitude": origin[0], "longitude": origin[1]}}},
            "destination": {
                "location": {"latLng": {"latitude": destination[0], "longitude": destination[1]}}
            },
            "travelMode": {"walk": "WALK", "bike": "BICYCLE"}.get(travel_mode, "DRIVE"),
            "computeAlternativeRoutes": False,
            "languageCode": "en-US",
            "units": "METRIC",
            "polylineQuality": "HIGH_QUALITY",
        }
    ).encode("utf-8")
    response = http_json(
        "https://routes.googleapis.com/directions/v2:computeRoutes",
        key=key,
        method="POST",
        headers=android_headers(package_name, cert_sha1)
        | {
            "Content-Type": "application/json; charset=utf-8",
            "X-Goog-Api-Key": key,
            "X-Goog-FieldMask": (
                "routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline,"
                "routes.legs.steps.startLocation,routes.legs.steps.distanceMeters,"
                "routes.legs.steps.staticDuration,routes.legs.steps.navigationInstruction"
            ),
        },
        body=body,
    )
    routes = response.get("routes") or []
    if not routes:
        raise FixtureError("Routes API returned no route.")
    return routes[0]


def world_point(latitude: float, longitude: float, zoom: int = ROUTE_WORLD_ZOOM) -> tuple[int, int]:
    safe_lat = min(max(latitude, MIN_WEB_MERCATOR_LAT), MAX_WEB_MERCATOR_LAT)
    wrapped_lng = ((longitude + 180.0) % 360.0 + 360.0) % 360.0 - 180.0
    lat_rad = math.radians(safe_lat)
    scale = (1 << zoom) * SOURCE_TILE_SIZE
    world_x = ((wrapped_lng + 180.0) / 360.0) * scale
    mercator = (1.0 - math.log(math.tan(lat_rad) + 1.0 / math.cos(lat_rad)) / math.pi) / 2.0
    world_y = mercator * scale
    return (round(world_x), round(world_y))


def decode_polyline(encoded: str) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    index = 0
    latitude = 0
    longitude = 0
    while index < len(encoded):
        lat_delta, index = decode_polyline_value(encoded, index)
        lng_delta, index = decode_polyline_value(encoded, index)
        latitude += lat_delta
        longitude += lng_delta
        points.append((latitude / 1e5, longitude / 1e5))
    return points


def decode_polyline_value(encoded: str, index: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while index < len(encoded):
        value = ord(encoded[index]) - 63
        index += 1
        result |= (value & 0x1F) << shift
        shift += 5
        if value < 0x20:
            break
    delta = ~(result >> 1) if result & 1 else result >> 1
    return delta, index


def downsample(items: list[Any], max_count: int) -> list[Any]:
    if len(items) <= max_count:
        return items
    return [items[round(index * (len(items) - 1) / (max_count - 1))] for index in range(max_count)]


def route_points(route: dict[str, Any]) -> list[tuple[int, int]]:
    encoded = ((route.get("polyline") or {}).get("encodedPolyline") or "").strip()
    if not encoded:
        raise FixtureError("Route response has no encoded polyline.")
    return [world_point(lat, lng) for lat, lng in downsample(decode_polyline(encoded), MAX_ROUTE_POINTS)]


def duration_seconds(value: str | None) -> int:
    if not value:
        return 0
    value = value.rstrip("s")
    try:
        return round(float(value))
    except ValueError:
        return 0


def truncate_utf8(value: str, limit: int = MAX_WATCH_TEXT_BYTES) -> str:
    output = bytearray()
    for char in value:
        data = char.encode("utf-8", errors="replace")
        if len(output) + len(data) > limit:
            break
        output.extend(data)
    return output.decode("utf-8", errors="replace")


def normalized_instruction(step: dict[str, Any], fallback: str) -> str:
    instruction = ((step.get("navigationInstruction") or {}).get("instructions") or fallback).strip()
    instruction = re.sub(r"<[^>]*>", " ", instruction)
    instruction = re.sub(r"\s+", " ", instruction).strip()
    return truncate_utf8(instruction or fallback)


def route_steps(route: dict[str, Any], fallback_start: tuple[int, int]) -> list[dict[str, Any]]:
    drafts: list[dict[str, Any]] = []
    for leg in route.get("legs") or []:
        for step in leg.get("steps") or []:
            lat_lng = (((step.get("startLocation") or {}).get("latLng")) or {})
            lat = lat_lng.get("latitude")
            lng = lat_lng.get("longitude")
            if lat is None or lng is None:
                continue
            x, y = world_point(float(lat), float(lng))
            drafts.append(
                {
                    "x": x,
                    "y": y,
                    "distanceMeters": int(step.get("distanceMeters") or 0),
                    "durationSeconds": duration_seconds(step.get("staticDuration")),
                    "instruction": normalized_instruction(step, "Continue"),
                }
            )
    drafts = downsample(drafts, MAX_NAV_STEPS)
    if not drafts:
        drafts = [
            {
                "x": fallback_start[0],
                "y": fallback_start[1],
                "distanceMeters": int(route.get("distanceMeters") or 0),
                "durationSeconds": duration_seconds(route.get("duration")),
                "instruction": "Head toward destination",
            }
        ]

    total_distance = sum(max(0, step["distanceMeters"]) for step in drafts)
    total_duration = sum(max(0, step["durationSeconds"]) for step in drafts)
    remaining_distance = total_distance
    remaining_duration = total_duration
    result: list[dict[str, Any]] = []
    for index, step in enumerate(drafts):
        result.append(
            {
                "index": index,
                "x": step["x"],
                "y": step["y"],
                "remainingMeters": min(65535, max(0, remaining_distance)),
                "remainingSeconds": min(65535, max(0, remaining_duration)),
                "instruction": step["instruction"],
            }
        )
        remaining_distance -= max(0, step["distanceMeters"])
        remaining_duration -= max(0, step["durationSeconds"])
    return result


def bearing_degrees(origin: tuple[float, float], destination: tuple[float, float]) -> int:
    lat1 = math.radians(origin[0])
    lat2 = math.radians(destination[0])
    delta_lng = math.radians(destination[1] - origin[1])
    x = math.sin(delta_lng) * math.cos(lat2)
    y = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(delta_lng)
    return round((math.degrees(math.atan2(x, y)) + 360.0) % 360.0)


def floor_div(value: int, divisor: int) -> int:
    return math.floor(value / divisor)


def crop_bank_range(
    origin_world: tuple[int, int],
    points: list[tuple[int, int]],
    *,
    screen_width: int,
    screen_height: int,
    margin: int,
    max_cols: int,
    max_rows: int,
) -> tuple[range, range]:
    left = origin_world[0] - screen_width // 2
    top = origin_world[1] - screen_height // 2
    start_col = floor_div(left, WATCH_TILE_WIDTH)
    start_row = floor_div(top, WATCH_TILE_HEIGHT)
    cols = [start_col - margin, start_col + 4 + margin]
    rows = [start_row - margin, start_row + 4 + margin]
    for x, y in points:
        cols.extend([floor_div(x, WATCH_TILE_WIDTH) - 1, floor_div(x, WATCH_TILE_WIDTH) + 1])
        rows.extend([floor_div(y, WATCH_TILE_HEIGHT) - 1, floor_div(y, WATCH_TILE_HEIGHT) + 1])

    min_col = min(cols)
    max_col = max(cols)
    min_row = min(rows)
    max_row = max(rows)
    if max_col - min_col + 1 > max_cols:
        center = floor_div(origin_world[0], WATCH_TILE_WIDTH)
        min_col = center - max_cols // 2
        max_col = min_col + max_cols - 1
    if max_row - min_row + 1 > max_rows:
        center = floor_div(origin_world[1], WATCH_TILE_HEIGHT)
        min_row = center - max_rows // 2
        max_row = min_row + max_rows - 1
    return range(min_col, max_col + 1), range(min_row, max_row + 1)


def source_tiles_for_crop(world_x: int, world_y: int, zoom: int) -> set[tuple[int, int]]:
    scale = 1 << zoom
    world_size = scale * SOURCE_TILE_SIZE
    keys: set[tuple[int, int]] = set()
    for dy in (0, WATCH_TILE_HEIGHT - 1):
        source_y = min(max(world_y + dy, 0), world_size - 1)
        tile_y = min(max(source_y // SOURCE_TILE_SIZE, 0), scale - 1)
        for dx in (0, WATCH_TILE_WIDTH - 1):
            source_x = (world_x + dx) % world_size
            tile_x = (source_x // SOURCE_TILE_SIZE) % scale
            keys.add((int(tile_x), int(tile_y)))
    return keys


def nearest_palette_index(rgb: tuple[int, int, int], palette: list[tuple[int, int, int]]) -> int:
    red, green, blue = rgb
    best_index = 0
    best_distance = sys.maxsize
    for index, (pr, pg, pb) in enumerate(palette):
        distance = (red - pr) ** 2 + (green - pg) ** 2 + (blue - pb) ** 2
        if distance < best_distance:
            best_distance = distance
            best_index = index
    return best_index


def rle_pack(indexes: list[int]) -> list[int]:
    if len(indexes) != WATCH_TILE_PIXELS:
        raise FixtureError(f"Expected {WATCH_TILE_PIXELS} pixels, got {len(indexes)}.")
    encoded: list[int] = []
    run_value = indexes[0] & 0x0F
    run_length = 0
    for raw in indexes:
        value = raw & 0x0F
        if value == run_value and run_length < 16:
            run_length += 1
            continue
        encoded.append(((run_length - 1) << 4) | run_value)
        run_value = value
        run_length = 1
    encoded.append(((run_length - 1) << 4) | run_value)
    return encoded


def crop_watch_tile(
    source_tiles: dict[tuple[int, int], Image.Image],
    world_x: int,
    world_y: int,
    zoom: int,
    palette: list[tuple[int, int, int]],
) -> list[int]:
    scale = 1 << zoom
    world_size = scale * SOURCE_TILE_SIZE
    indexes: list[int] = []
    for pixel_y in range(WATCH_TILE_HEIGHT):
        source_world_y = min(max(world_y + pixel_y, 0), world_size - 1)
        source_tile_y = min(max(source_world_y // SOURCE_TILE_SIZE, 0), scale - 1)
        source_pixel_y = source_world_y - source_tile_y * SOURCE_TILE_SIZE
        for pixel_x in range(WATCH_TILE_WIDTH):
            source_world_x = (world_x + pixel_x) % world_size
            source_tile_x = (source_world_x // SOURCE_TILE_SIZE) % scale
            source_pixel_x = source_world_x - source_tile_x * SOURCE_TILE_SIZE
            image = source_tiles[(int(source_tile_x), int(source_tile_y))]
            indexes.append(nearest_palette_index(image.getpixel((source_pixel_x, source_pixel_y)), palette))
    return rle_pack(indexes)


def i32le(value: int) -> list[int]:
    value &= 0xFFFFFFFF
    return [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF, (value >> 24) & 0xFF]


def u16le(value: int) -> list[int]:
    value &= 0xFFFF
    return [value & 0xFF, (value >> 8) & 0xFF]


def encode_text(value: str, limit: int) -> list[int]:
    return list(truncate_utf8(value, limit).encode("utf-8"))


def encode_destinations(
    destination_label: str,
    destination_lat_lng: tuple[float, float],
    origin_label: str,
    origin_lat_lng: tuple[float, float],
) -> list[int]:
    records = [
        (0, 2, 2, destination_lat_lng[0], destination_lat_lng[1], destination_label),
        (1, 2, 0, origin_lat_lng[0], origin_lat_lng[1], origin_label),
    ]
    payload = [0x80 | len(records)]
    for slot, kind, mode, lat, lng, label in records:
        label_bytes = encode_text(label, 30)
        payload.extend([slot, kind, mode])
        payload.extend(i32le(round(lat * 10_000_000)))
        payload.extend(i32le(round(lng * 10_000_000)))
        payload.append(len(label_bytes))
        payload.extend(label_bytes)
    return payload


def encode_route_payload(points: list[tuple[int, int]]) -> list[int]:
    payload = u16le(len(points)) + [ROUTE_WORLD_ZOOM]
    for x, y in points:
        payload.extend(i32le(x))
        payload.extend(i32le(y))
    return payload


def encode_nav_payload(steps: list[dict[str, Any]], first_index: int) -> list[int]:
    chunk = steps[first_index : first_index + 3]
    payload = [len(steps), first_index, len(chunk)]
    for step in chunk:
        instruction = encode_text(step["instruction"], MAX_WATCH_TEXT_BYTES)
        payload.append(step["index"] & 0xFF)
        payload.extend(i32le(step["x"]))
        payload.extend(i32le(step["y"]))
        payload.extend(u16le(step["remainingMeters"]))
        payload.extend(u16le(step["remainingSeconds"]))
        payload.append(len(instruction))
        payload.extend(instruction)
    return payload


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def write_pkjs(path: Path, fixture: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fixture_json = json.dumps(fixture, separators=(",", ":"))
    content = f"""// Generated by tooling/generate-real-map-fixtures.py.
// Development-only PKJS mock. Contains derived map fixture payloads, not an API key.
(function() {{
  'use strict';

  var KEY_CMD = {KEY_CMD};
  var KEY_IS_COLOR = {KEY_IS_COLOR};
  var KEY_BUTTON_ID = {KEY_BUTTON_ID};
  var KEY_WORLD_X = {KEY_WORLD_X};
  var KEY_WORLD_Y = {KEY_WORLD_Y};
  var KEY_TILE_ZOOM = {KEY_TILE_ZOOM};
  var KEY_REQUEST_ID = {KEY_REQUEST_ID};
  var CMD_INIT = {CMD_INIT};
  var CMD_PHONE_READY = {CMD_PHONE_READY};
  var CMD_GPS = {CMD_GPS};
  var CMD_TILE_REQUEST = {CMD_TILE_REQUEST};
  var CMD_TILE = {CMD_TILE};
  var CMD_THEME = {CMD_THEME};
  var CMD_DESTINATIONS = {CMD_DESTINATIONS};
  var CMD_ROUTE_REQUEST = {CMD_ROUTE_REQUEST};
  var CMD_ROUTE_POINTS = {CMD_ROUTE_POINTS};
  var CMD_ROUTE_CLEAR = {CMD_ROUTE_CLEAR};
  var CMD_TRAVEL_MODE = {CMD_TRAVEL_MODE};
  var CMD_NAV_STEPS = {CMD_NAV_STEPS};
  var CMD_UNITS = {CMD_UNITS};
  var CMD_BACKLIGHT = {CMD_BACKLIGHT};
  var CMD_ERROR_STATE = {CMD_ERROR_STATE};
  var CMD_TILE_ANIMATION = {CMD_TILE_ANIMATION};
  var FIXTURE = {fixture_json};
  var FIXTURE_OPTIONS = Pebble.__mappyFixtureOptions || {{}};
  var txQueue = [];
  var txBusy = false;
  var didSendStartupState = false;
  var txSuccessDelayMs = numberOption('txSuccessDelayMs', 45, 0, 5000);
  var txFailureDelayMs = numberOption('txFailureDelayMs', 180, 0, 5000);
  var tileDelayMs = numberOption('tileDelayMs', 0, 0, 60000);
  var tileStaggerMs = numberOption('tileStaggerMs', 0, 0, 60000);
  var tileAnimationMode = numberOption('tileAnimationMode', -1, -1, 2);
  var tileSequence = 0;

  function numberOption(name, fallback, minValue, maxValue) {{
    var value = Number(FIXTURE_OPTIONS[name]);
    if (!isFinite(value)) return fallback;
    value = Math.round(value);
    return Math.max(minValue, Math.min(maxValue, value));
  }}

  function pick(payload, name, id) {{
    if (payload[name] !== undefined) return payload[name];
    if (payload[String(id)] !== undefined) return payload[String(id)];
    return undefined;
  }}

  function summarize(dict) {{
    var clone = {{}};
    for (var key in dict) {{
      if (!Object.prototype.hasOwnProperty.call(dict, key)) continue;
      if (key === 'chunk_data' && dict[key] && dict[key].length !== undefined) {{
        clone[key] = '<' + dict[key].length + ' bytes>';
      }} else {{
        clone[key] = dict[key];
      }}
    }}
    return clone;
  }}

  function enqueue(label, dict) {{
    txQueue.push({{ label: label, dict: dict }});
    pumpQueue();
  }}

  function enqueueDelayed(label, dict, delayMs) {{
    if (delayMs <= 0) {{
      enqueue(label, dict);
      return;
    }}
    console.log('[mappy-real-fixture] delay ' + label + ' ' + delayMs + 'ms ' +
      JSON.stringify(summarize(dict)));
    setTimeout(function() {{
      enqueue(label, dict);
    }}, delayMs);
  }}

  function enqueueTile(label, dict) {{
    var delayMs = tileDelayMs + (tileSequence * tileStaggerMs);
    tileSequence += 1;
    enqueueDelayed(label, dict, delayMs);
  }}

  function pumpQueue() {{
    if (txBusy || txQueue.length === 0) return;
    var next = txQueue.shift();
    txBusy = true;
    console.log('[mappy-real-fixture] tx ' + next.label + ' ' + JSON.stringify(summarize(next.dict)));
    Pebble.sendAppMessage(next.dict, function() {{
      txBusy = false;
      setTimeout(pumpQueue, txSuccessDelayMs);
    }}, function(e) {{
      txBusy = false;
      console.log('[mappy-real-fixture] tx-fail ' + next.label + ' ' + JSON.stringify(e));
      setTimeout(pumpQueue, txFailureDelayMs);
    }});
  }}

  function sendStartupState() {{
    if (didSendStartupState) return;
    didSendStartupState = true;
    enqueue('phone-ready', {{ cmd: CMD_PHONE_READY, protocol_version: 2 }});
    enqueue('theme', {{ cmd: CMD_THEME, button_id: 1 }});
    enqueue('units', {{ cmd: CMD_UNITS, button_id: 1 }});
    enqueue('backlight', {{ cmd: CMD_BACKLIGHT, button_id: 0 }});
    if (tileAnimationMode >= 0) {{
      enqueue('tile-animation', {{ cmd: CMD_TILE_ANIMATION, button_id: tileAnimationMode }});
    }}
    enqueue('destinations', {{
      cmd: CMD_DESTINATIONS,
      total_bytes: FIXTURE.destinationsPayload.length,
      chunk_data: FIXTURE.destinationsPayload
    }});
    enqueue('gps', {{
      cmd: CMD_GPS,
      world_x: FIXTURE.gps.worldX,
      world_y: FIXTURE.gps.worldY,
      tile_zoom: FIXTURE.gps.zoom,
      button_id: FIXTURE.gps.heading
    }});
  }}

  function tileKey(wx, wy, zoom, theme) {{
    return wx + ':' + wy + ':' + zoom + ':' + theme;
  }}

  function clamp(value, minValue, maxValue) {{
    return Math.max(minValue, Math.min(maxValue, value));
  }}

  function snapToGrid(value, origin, step) {{
    return origin + Math.round((value - origin) / step) * step;
  }}

  function findFixtureTile(wx, wy, zoom, theme) {{
    var direct = FIXTURE.tiles[tileKey(wx, wy, zoom, theme)] ||
      FIXTURE.tiles[tileKey(wx, wy, zoom, 1)];
    if (direct) {{
      return {{ data: direct, fallback: false }};
    }}

    var factor = Math.pow(2, FIXTURE.gps.zoom - zoom);
    var baseX = Math.round(wx * factor);
    var baseY = Math.round(wy * factor);
    var clampedX = clamp(baseX, FIXTURE.bank.minWorldX, FIXTURE.bank.maxWorldX);
    var clampedY = clamp(baseY, FIXTURE.bank.minWorldY, FIXTURE.bank.maxWorldY);
    var snappedX = clamp(snapToGrid(clampedX, FIXTURE.bank.minWorldX, {WATCH_TILE_WIDTH}),
      FIXTURE.bank.minWorldX, FIXTURE.bank.maxWorldX);
    var snappedY = clamp(snapToGrid(clampedY, FIXTURE.bank.minWorldY, {WATCH_TILE_HEIGHT}),
      FIXTURE.bank.minWorldY, FIXTURE.bank.maxWorldY);
    var fallback = FIXTURE.tiles[tileKey(snappedX, snappedY, FIXTURE.gps.zoom, theme)] ||
      FIXTURE.tiles[tileKey(snappedX, snappedY, FIXTURE.gps.zoom, 1)];
    if (!fallback) {{
      return null;
    }}
    return {{
      data: fallback,
      fallback: true,
      sourceX: snappedX,
      sourceY: snappedY,
      sourceZoom: FIXTURE.gps.zoom
    }};
  }}

  Pebble.addEventListener('ready', function() {{
    console.log('[mappy-real-fixture] ready ' + FIXTURE.name);
    console.log('[mappy-real-fixture] options ' + JSON.stringify(FIXTURE_OPTIONS));
    sendStartupState();
  }});

  Pebble.addEventListener('appmessage', function(e) {{
    var payload = e.payload || {{}};
    var cmd = Number(pick(payload, 'cmd', KEY_CMD));
    console.log('[mappy-real-fixture] rx cmd=' + cmd + ' ' + JSON.stringify(payload));

    if (cmd === CMD_INIT) {{
      sendStartupState();
      return;
    }}

    if (cmd === CMD_TILE_REQUEST) {{
      var wx = Number(pick(payload, 'world_x', KEY_WORLD_X) || 0);
      var wy = Number(pick(payload, 'world_y', KEY_WORLD_Y) || 0);
      var zoom = Number(pick(payload, 'tile_zoom', KEY_TILE_ZOOM) || FIXTURE.gps.zoom);
      var theme = Number(pick(payload, 'is_color', KEY_IS_COLOR) || 1);
      var requestId = Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 0);
      var tileResult = findFixtureTile(wx, wy, zoom, theme);
      if (!tileResult) {{
        enqueue('tile-outside-fixture', {{
          cmd: CMD_ERROR_STATE,
          button_id: 5,
          chunk_index: CMD_TILE_REQUEST,
          world_x: wx,
          world_y: wy,
          tile_zoom: zoom,
          instruction: 'Tile outside fixture'
        }});
        return;
      }}
      if (tileResult.fallback) {{
        console.log('[mappy-real-fixture] tile fallback ' + wx + ':' + wy + ':' + zoom +
          ' -> ' + tileResult.sourceX + ':' + tileResult.sourceY + ':' + tileResult.sourceZoom);
      }}
      enqueueTile(tileResult.fallback ? 'tile-fallback' : 'tile', {{
        cmd: CMD_TILE,
        world_x: wx,
        world_y: wy,
        tile_zoom: zoom,
        total_bytes: tileResult.data.length,
        request_id: requestId,
        chunk_data: tileResult.data
      }});
      return;
    }}

    if (cmd === CMD_ROUTE_REQUEST) {{
      var slot = Number(pick(payload, 'button_id', KEY_BUTTON_ID) || 0);
      if (slot !== 0) {{
        enqueue('empty-slot', {{
          cmd: CMD_ERROR_STATE,
          button_id: 8,
          chunk_index: CMD_ROUTE_REQUEST,
          chunk_offset: slot,
          instruction: 'Destination not configured'
        }});
        return;
      }}
      var routeRequestId = Number(pick(payload, 'request_id', KEY_REQUEST_ID) || 1);
      enqueue('route', {{ cmd: CMD_ROUTE_POINTS, button_id: 1, request_id: routeRequestId,
        total_bytes: 1, chunk_index: 1, chunk_data: FIXTURE.routePayload }});
      enqueue('nav', {{ cmd: CMD_NAV_STEPS, request_id: routeRequestId,
        total_bytes: 1, chunk_data: FIXTURE.navPayloads['0'] }});
      return;
    }}

    if (cmd === CMD_NAV_STEPS) {{
      var first = String(Number(pick(payload, 'button_id', KEY_BUTTON_ID) || 0));
      enqueue('nav-request', {{
        cmd: CMD_NAV_STEPS,
        chunk_data: FIXTURE.navPayloads[first] || FIXTURE.navPayloads['0']
      }});
      return;
    }}

    if (cmd === CMD_ROUTE_CLEAR) {{
      enqueue('route-clear', {{ cmd: CMD_ROUTE_CLEAR }});
      return;
    }}

    if (cmd === CMD_TRAVEL_MODE) {{
      var travelMode = pick(payload, 'button_id', KEY_BUTTON_ID);
      enqueue('travel-mode', {{
        cmd: CMD_TRAVEL_MODE,
        button_id: Number(travelMode === undefined ? 2 : travelMode)
      }});
    }}
  }});
}})();
"""
    path.write_text(content, encoding="utf-8")


def parse_lat_lng(value: str) -> tuple[float, float]:
    lat, lng = value.split(",", 1)
    return (float(lat.strip()), float(lng.strip()))


def build_fixture(args: argparse.Namespace) -> dict[str, Any]:
    local_properties = Path(args.local_properties)
    key = load_api_key(args.api_key, Path(args.env_file), local_properties)
    cert_sha1 = args.android_cert_sha1 or debug_cert_sha1(Path(args.debug_keystore))
    package_name = args.android_package

    origin = parse_lat_lng(args.origin)
    destination = parse_lat_lng(args.destination)
    origin_world = world_point(origin[0], origin[1])
    heading = bearing_degrees(origin, destination)

    print("Creating Map Tiles session...")
    session = create_tile_session(key, package_name, cert_sha1)
    session_token = session["session"]

    print("Computing real route...")
    route = compute_route(key, package_name, cert_sha1, origin, destination, args.travel_mode)
    points = route_points(route)
    if len(points) < 2:
        raise FixtureError("Route did not produce at least two watch points.")
    steps = route_steps(route, points[0])

    col_range, row_range = crop_bank_range(
        origin_world,
        points,
        screen_width=args.screen_width,
        screen_height=args.screen_height,
        margin=args.bank_margin,
        max_cols=args.max_cols,
        max_rows=args.max_rows,
    )
    crop_origins = [(col * WATCH_TILE_WIDTH, row * WATCH_TILE_HEIGHT) for row in row_range for col in col_range]
    source_keys: set[tuple[int, int]] = set()
    for world_x, world_y in crop_origins:
        source_keys |= source_tiles_for_crop(world_x, world_y, ROUTE_WORLD_ZOOM)

    print(f"Fetching {len(source_keys)} source tiles for {len(crop_origins)} watch crops...")
    source_tiles: dict[tuple[int, int], Image.Image] = {}
    for index, (tile_x, tile_y) in enumerate(sorted(source_keys), start=1):
        print(f"  source tile {index}/{len(source_keys)} z{ROUTE_WORLD_ZOOM}/{tile_x}/{tile_y}")
        source_tiles[(tile_x, tile_y)] = fetch_source_tile(
            key, package_name, cert_sha1, session_token, ROUTE_WORLD_ZOOM, tile_x, tile_y
        )

    themes = [(1, DAY_PALETTE)]
    if args.include_night:
        themes.append((2, NIGHT_PALETTE))

    tiles: dict[str, list[int]] = {}
    for theme, palette in themes:
        print(f"Encoding {len(crop_origins)} watch crops for theme {theme}...")
        for world_x, world_y in crop_origins:
            key_name = f"{world_x}:{world_y}:{ROUTE_WORLD_ZOOM}:{theme}"
            tiles[key_name] = crop_watch_tile(source_tiles, world_x, world_y, ROUTE_WORLD_ZOOM, palette)

    nav_payloads = {
        str(first): encode_nav_payload(steps, first)
        for first in range(0, len(steps), 3)
    }
    if "0" not in nav_payloads:
        nav_payloads["0"] = encode_nav_payload(steps, 0)

    fixture = {
        "name": args.name,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "Google Map Tiles API and Routes API derived fixture",
        "attribution": "Contains derived Google Map Tiles data for local development only.",
        "androidPackage": package_name,
        "androidCertSha1Present": bool(cert_sha1),
        "gps": {
            "latitude": origin[0],
            "longitude": origin[1],
            "worldX": origin_world[0],
            "worldY": origin_world[1],
            "zoom": ROUTE_WORLD_ZOOM,
            "heading": heading,
        },
        "destination": {
            "label": args.destination_label,
            "address": args.destination_address,
            "latitude": destination[0],
            "longitude": destination[1],
        },
        "bank": {
            "cols": len(col_range),
            "rows": len(row_range),
            "minWorldX": min(x for x, _ in crop_origins),
            "maxWorldX": max(x for x, _ in crop_origins),
            "minWorldY": min(y for _, y in crop_origins),
            "maxWorldY": max(y for _, y in crop_origins),
            "tileCount": len(crop_origins),
        },
        "routeSummary": {
            "distanceMeters": int(route.get("distanceMeters") or 0),
            "durationSeconds": duration_seconds(route.get("duration")),
            "pointCount": len(points),
            "stepCount": len(steps),
            "travelMode": args.travel_mode,
        },
        "destinationsPayload": encode_destinations(
            args.destination_label,
            destination,
            "Example Origin",
            origin,
        ),
        "routePayload": encode_route_payload(points),
        "navPayloads": nav_payloads,
        "tiles": tiles,
    }
    return fixture


def main(argv: list[str]) -> int:
    root = repo_root()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", default="sample-real-map")
    parser.add_argument(
        "--api-key",
        default=None,
        help="Optional explicit key (visible in the process list); prefer the environment or .env.local.",
    )
    parser.add_argument("--env-file", default=str(root / ".env.local"))
    parser.add_argument(
        "--local-properties",
        default=str(root / "apps" / "mobile-companion" / "android" / "local.properties"),
    )
    parser.add_argument("--android-package", default="com.leapwardkoex.mappy")
    parser.add_argument("--android-cert-sha1", default=None)
    parser.add_argument("--debug-keystore", default=str(default_debug_keystore()))
    parser.add_argument("--origin", default=f"{DEFAULT_ORIGIN[0]},{DEFAULT_ORIGIN[1]}")
    parser.add_argument("--destination", default=f"{DEFAULT_DESTINATION[0]},{DEFAULT_DESTINATION[1]}")
    parser.add_argument("--destination-label", default=DEFAULT_DESTINATION_LABEL)
    parser.add_argument("--destination-address", default=DEFAULT_DESTINATION_ADDRESS)
    parser.add_argument("--travel-mode", choices=("drive", "walk", "bike"), default="drive")
    parser.add_argument("--screen-width", type=int, default=EMERY_WIDTH)
    parser.add_argument("--screen-height", type=int, default=EMERY_HEIGHT)
    parser.add_argument("--bank-margin", type=int, default=4)
    parser.add_argument("--max-cols", type=int, default=17)
    parser.add_argument("--max-rows", type=int, default=17)
    parser.add_argument("--include-night", action="store_true")
    parser.add_argument(
        "--json-output",
        default=str(root / "tooling" / "real-map-fixtures" / "generated" / "sample-fixture.json"),
    )
    parser.add_argument(
        "--pkjs-output",
        default=str(root / "tooling" / "real-map-fixtures" / "generated" / "pebble-map-real-fixture-pkjs.js"),
    )
    args = parser.parse_args(argv)

    try:
        fixture = build_fixture(args)
        write_json(Path(args.json_output), fixture)
        write_pkjs(Path(args.pkjs_output), fixture)
    except FixtureError as exc:
        print(f"fixture generation failed: {exc}", file=sys.stderr)
        return 1

    print(f"Wrote JSON fixture: {args.json_output}")
    print(f"Wrote PKJS mock: {args.pkjs_output}")
    print(
        "Fixture summary: "
        f"{fixture['bank']['cols']}x{fixture['bank']['rows']} crops, "
        f"{fixture['routeSummary']['pointCount']} route points, "
        f"{fixture['routeSummary']['stepCount']} nav steps."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
