#!/usr/bin/env python3
"""Verify Mappy protocol identifiers across the watch, phone, specs, and tools."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def fail(message: str) -> None:
    raise AssertionError(message)


def expect_equal(label: str, actual: object, expected: object) -> None:
    if actual != expected:
        fail(f"{label} differs\nactual:   {actual}\nexpected: {expected}")


def camel_to_upper_snake(value: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", value).upper()


def verify_fixture(
    label: str,
    fixture: str,
    canonical_keys: dict[str, int],
    canonical_commands: dict[str, int],
) -> None:
    fixture_keys = {
        name: int(value)
        for name, value in re.findall(r"^\s+var KEY_([A-Z0-9_]+) = (\d+);$", fixture, re.M)
    }
    fixture_commands = {
        name: int(value)
        for name, value in re.findall(r"^\s+var CMD_([A-Z0-9_]+) = (\d+);$", fixture, re.M)
    }
    expected_fixture_keys = {
        camel_to_upper_snake(name): value
        for name, value in canonical_keys.items()
        if camel_to_upper_snake(name) in fixture_keys
    }
    expect_equal(f"{label} message keys", fixture_keys, expected_fixture_keys)
    if not fixture_commands.items() <= canonical_commands.items():
        fail(f"{label} contains an unknown command")


def main() -> int:
    package = json.loads(read("apps/pebble-watch/package.json"))["pebble"]
    canonical_keys = {name: int(value) for name, value in package["messageKeys"].items()}

    c_header = read("apps/pebble-watch/src/c/mappy.h")
    c_keys = {
        name: int(value)
        for name, value in re.findall(r"^#define MESSAGE_KEY_([a-z0-9_]+)\s+(\d+)$", c_header, re.M)
    }
    canonical_commands = {
        name: int(value)
        for name, value in re.findall(r"^#define CMD_([A-Z0-9_]+)\s+(\d+)$", c_header, re.M)
    }
    expect_equal("C message keys", c_keys, canonical_keys)

    kotlin = read(
        "apps/mobile-companion/android/app/src/main/kotlin/"
        "com/leapwardkoex/mappy/NativeBridgeConstants.kt"
    )
    kotlin_key_names = {
        symbol: name
        for symbol, name in re.findall(
            r'^internal const val (KEY_[A-Z0-9_]+) = "([a-z0-9_]+)"$', kotlin, re.M
        )
    }
    kotlin_keys = {
        kotlin_key_names[symbol]: int(value)
        for symbol, value in re.findall(r"^\s+(KEY_[A-Z0-9_]+) to (\d+),?$", kotlin, re.M)
        if symbol in kotlin_key_names
    }
    kotlin_commands = {
        name: int(value)
        for name, value in re.findall(
            r"^internal const val CMD_([A-Z0-9_]+) = (\d+)$", kotlin, re.M
        )
    }
    expect_equal("Kotlin message keys", kotlin_keys, canonical_keys)
    expect_equal("Kotlin commands", kotlin_commands, canonical_commands)

    dart = read("apps/mobile-companion/lib/watch_protocol.dart")
    dart_keys_block = re.search(
        r"abstract final class WatchKeys \{(.*?)\n\}", dart, re.S
    )
    dart_commands_block = re.search(
        r"abstract final class WatchCommands \{(.*?)\n\}", dart, re.S
    )
    if dart_keys_block is None or dart_commands_block is None:
        fail("Dart protocol classes were not found")
    dart_key_names = {
        name
        for _, name in re.findall(
            r"static const ([A-Za-z0-9_]+) = '([a-z0-9_]+)';", dart_keys_block.group(1)
        )
    }
    dart_commands = {
        camel_to_upper_snake(name): int(value)
        for name, value in re.findall(
            r"static const ([A-Za-z0-9_]+) = (\d+);", dart_commands_block.group(1)
        )
    }
    expect_equal("Dart message-key names", dart_key_names, set(canonical_keys))
    expect_equal("Dart commands", dart_commands, canonical_commands)

    # Protocol v4 activates the formerly reserved codec key. All runtimes must
    # agree even though they have different naming conventions.
    expect_equal("watch protocol version", int(re.search(r"#define WATCH_PROTOCOL_VERSION (\d+)", c_header).group(1)), 4)
    expect_equal("Android protocol version", int(re.search(r"WATCH_PROTOCOL_VERSION = (\d+)", kotlin).group(1)), 4)
    expect_equal("Dart protocol version", int(re.search(r"watchProtocolVersion = (\d+)", dart).group(1)), 4)
    expected_codecs = {"RLE": 1, "PACKED": 2, "LZ4_PACKED": 3, "LZ4_RLE": 4}
    kotlin_codecs = {name: int(value) for name, value in re.findall(r"TILE_COMPRESSION_([A-Z0-9_]+) = (\d+)", kotlin)}
    expect_equal("Android tile codecs", kotlin_codecs, expected_codecs)
    c_codec = read("apps/pebble-watch/src/c/tile_codec.h")
    c_codec_names = {"Rle": "RLE", "Packed": "PACKED", "Lz4Packed": "LZ4_PACKED", "Lz4Rle": "LZ4_RLE"}
    c_codecs = {c_codec_names[name]: int(value) for name, value in re.findall(r"TileCompression([A-Za-z0-9]+) = (\d+)", c_codec)}
    expect_equal("watch tile codecs", c_codecs, expected_codecs)
    dart_codec_block = re.search(r"abstract final class WatchTileCompression \{(.*?)\n\}", dart, re.S)
    if dart_codec_block is None:
        fail("Dart tile codec constants were not found")
    dart_codecs = {camel_to_upper_snake(name): int(value) for name, value in re.findall(r"static const ([A-Za-z0-9]+) = (\d+);", dart_codec_block.group(1))}
    expect_equal("Dart tile codecs", dart_codecs, expected_codecs)

    protocol_spec = read("specs/shared/PROTOCOL_MVP.md")
    documented_keys = {
        name: int(value)
        for name, value in re.findall(
            r"^\| `([a-z0-9_]+)` \| (\d+) \| (?:both|phone -> watch|watch -> phone|reserved) \|",
            protocol_spec,
            re.M,
        )
    }
    expect_equal("documented message keys", documented_keys, canonical_keys)
    documented_commands = {
        name.removeprefix("CMD_"): int(value)
        for value, name in re.findall(
            r"^\|\s*(\d+)\s*\|\s*`(CMD_[A-Z0-9_]+)`\s*\|", protocol_spec, re.M
        )
    }
    expect_equal("documented commands", documented_commands, canonical_commands)

    allowed_key_ids = set(canonical_keys.values())
    allowed_command_ids = set(canonical_commands.values())
    script_expectations = {
        "tooling/pebble-emulator-codex.sh": {204, 205, 206, 901, 902, 903},
    }
    for relative, expected_commands in script_expectations.items():
        script = read(relative)
        used_keys = {int(value) for value in re.findall(r"\b(\d+)=", script)}
        unknown_keys = used_keys - allowed_key_ids
        if unknown_keys:
            fail(f"{relative} uses unknown message-key IDs: {sorted(unknown_keys)}")
        used_commands = {int(value) for value in re.findall(r"\b50=(\d+)", script)}
        if not used_commands <= allowed_command_ids:
            fail(f"{relative} uses unknown command IDs: {sorted(used_commands - allowed_command_ids)}")
        expect_equal(f"{relative} command coverage", used_commands, expected_commands)

    verify_fixture(
        "synthetic fixture",
        read("tooling/pebble-map-mock-pkjs.js"),
        canonical_keys,
        canonical_commands,
    )

    local_fixture_path = ROOT / "tooling/real-map-fixtures/generated/pebble-map-real-fixture-pkjs.js"
    if local_fixture_path.exists():
        verify_fixture(
            "local provider-map fixture",
            local_fixture_path.read_text(encoding="utf-8"),
            canonical_keys,
            canonical_commands,
        )

    generator = read("tooling/generate-real-map-fixtures.py")
    generator_keys = {
        name: int(value)
        for name, value in re.findall(r"^KEY_([A-Z0-9_]+) = (\d+)$", generator, re.M)
    }
    generator_commands = {
        name: int(value)
        for name, value in re.findall(r"^CMD_([A-Z0-9_]+) = (\d+)$", generator, re.M)
    }
    expected_generator_keys = {
        camel_to_upper_snake(name): value
        for name, value in canonical_keys.items()
        if camel_to_upper_snake(name) in generator_keys
    }
    expect_equal("local fixture generator message keys", generator_keys, expected_generator_keys)
    if not generator_commands.items() <= canonical_commands.items():
        fail("local fixture generator contains an unknown command")

    kotlin_uuid_match = re.search(r'UUID\.fromString\("([0-9a-f-]+)"\)', kotlin)
    if kotlin_uuid_match is None:
        fail("Kotlin watch UUID was not found")
    expect_equal("watch UUID", kotlin_uuid_match.group(1), package["uuid"])

    print(
        f"protocol consistency: {len(canonical_keys)} keys, "
        f"{len(canonical_commands)} commands, watch UUID {package['uuid']}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"protocol consistency failed: {error}", file=sys.stderr)
        raise SystemExit(1)
