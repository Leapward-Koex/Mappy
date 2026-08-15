#!/usr/bin/env python3
"""Regression checks for the repository Pebble development workflow."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
GENERATOR_PATH = ROOT / "tooling" / "generate-real-map-fixtures.py"


def load_generator():
    spec = importlib.util.spec_from_file_location("mappy_real_fixture_generator", GENERATOR_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {GENERATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


GENERATOR = load_generator()


class CredentialLoadingTest(unittest.TestCase):
    def test_key_precedence_and_dotenv_quotes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            env_file = root / ".env.local"
            properties = root / "local.properties"
            env_file.write_text(
                'export MAPPY_DEV_GOOGLE_API_KEY="dotenv-key"\n', encoding="utf-8"
            )
            properties.write_text("mappy.devGoogleApiKey=properties-key\n", encoding="utf-8")

            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(
                    GENERATOR.load_api_key("explicit-key", env_file, properties),
                    "explicit-key",
                )
                self.assertEqual(
                    GENERATOR.load_api_key(None, env_file, properties),
                    "dotenv-key",
                )

            with mock.patch.dict(
                os.environ,
                {"MAPPY_DEV_GOOGLE_API_KEY": "process-key"},
                clear=True,
            ):
                self.assertEqual(
                    GENERATOR.load_api_key(None, env_file, properties),
                    "process-key",
                )

    def test_legacy_fallback_and_missing_key(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            env_file = root / ".env.local"
            properties = root / "local.properties"
            properties.write_text("mappy.devGoogleApiKey=legacy-key\n", encoding="utf-8")
            with mock.patch.dict(os.environ, {}, clear=True):
                self.assertEqual(
                    GENERATOR.load_api_key(None, env_file, properties),
                    "legacy-key",
                )
                properties.unlink()
                with self.assertRaises(GENERATOR.FixtureError):
                    GENERATOR.load_api_key(None, env_file, properties)

    def test_mask_key_redacts_google_key_shapes(self) -> None:
        key = "AIza" + "A" * 24
        masked = GENERATOR.mask_key(f"request failed for {key}", key)
        self.assertNotIn(key, masked)
        self.assertIn("[redacted-google-key]", masked)


class RepositoryWorkflowTest(unittest.TestCase):
    def test_tile_animation_host_contract(self) -> None:
        compiler = shutil.which(os.environ.get("CC", "cc"))
        self.assertIsNotNone(compiler, "C compiler is required for host tests")
        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "mappy-tile-animation-tests"
            subprocess.run(
                [
                    compiler,
                    "-std=c99",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-DPBL_TOUCH",
                    "-DMAPPY_H",
                    "-include",
                    str(ROOT / "tooling" / "tile-animation-host-shim.h"),
                    str(ROOT / "tooling" / "test-tile-animation.c"),
                    str(
                        ROOT
                        / "apps"
                        / "pebble-watch"
                        / "src"
                        / "c"
                        / "tile_animation.c"
                    ),
                    "-o",
                    str(output),
                ],
                check=True,
            )
            subprocess.run([str(output)], check=True)

    def test_tile_animation_constants_and_touch_cancellation(self) -> None:
        header = (
            ROOT / "apps" / "pebble-watch" / "src" / "c" / "mappy.h"
        ).read_text(encoding="utf-8")

        def macro_value(name: str) -> int:
            match = re.search(rf"^#define {name} (\d+)$", header, re.MULTILINE)
            self.assertIsNotNone(match, f"missing {name}")
            return int(match.group(1))

        self.assertEqual(macro_value("TILE_ANIMATION_FADE_MS"), 180)
        self.assertEqual(macro_value("TILE_ANIMATION_FADE_ZOOM_MS"), 220)
        self.assertEqual(macro_value("TILE_ANIMATION_ZOOM_START_Q8"), 236)
        self.assertEqual(macro_value("TILE_ANIMATION_TICK_MS"), 40)
        self.assertEqual(macro_value("TILE_ANIMATION_MAX_ACTIVE"), 2)

        render_source = (
            ROOT / "apps" / "pebble-watch" / "src" / "c" / "render.c"
        ).read_text(encoding="utf-8")
        fade_arguments = re.findall(
            r"tile_animation_draws_pixel\(\s*[\w.>\-]+\s*,\s*[\w.>\-]+\s*,"
            r"\s*([\w.>\-]+)\s*\)",
            render_source,
        )
        self.assertEqual(len(fade_arguments), 3)
        self.assertTrue(
            all(argument.endswith("visibility_q8") for argument in fade_arguments),
            "every rendering path must dither with eased visibility",
        )

        input_source = (
            ROOT / "apps" / "pebble-watch" / "src" / "c" / "input.c"
        ).read_text(encoding="utf-8")
        pan_start = input_source.index("void begin_pan_interaction")
        pan_end = input_source.index("void end_pan_interaction", pan_start)
        pan_body = input_source[pan_start:pan_end]
        self.assertIn("complete_tile_animations();", pan_body)

        scheduler_source = (
            ROOT
            / "apps"
            / "pebble-watch"
            / "src"
            / "c"
            / "animation_scheduler.c"
        ).read_text(encoding="utf-8")
        cadence_end = scheduler_source.index("bool visual_animations_active")
        cadence_body = scheduler_source[:cadence_end]
        self.assertIn("return non_tile_active ?", cadence_body)
        self.assertIn("TILE_ANIMATION_TICK_MS", cadence_body)
        self.assertIn("VISUAL_ANIMATION_TICK_MS", cadence_body)
        schedule_start = scheduler_source.index("void schedule_visual_animation_tick")
        release_start = scheduler_source.index(
            "void release_visual_animation_tick_if_idle", schedule_start
        )
        schedule_body = scheduler_source[schedule_start:release_start]
        self.assertIn("if (!s_visual_animation_timer)", schedule_body)
        self.assertIn("complete_tile_animations();", schedule_body)

    def test_watch_reserves_appmessage_before_bounded_tile_storage(self) -> None:
        main_source = (
            ROOT / "apps" / "pebble-watch" / "src" / "c" / "main.c"
        ).read_text(encoding="utf-8")

        app_message_open = main_source.index("app_message_open(4096, 512)")
        tile_entries = main_source.index(
            "calloc(TILE_CACHE_SIZE, sizeof(TileCacheEntry))"
        )
        tile_storage = main_source.index(
            "malloc(TILE_STORAGE_ARENA_BYTES)"
        )
        tile_decode_scratch = main_source.index("malloc(MAX_TILE_BYTES)")
        tile_configuration = main_source.index(
            "configure_tile_geometry(DEFAULT_TILE_W, DEFAULT_TILE_H)"
        )

        self.assertLess(app_message_open, tile_entries)
        self.assertLess(app_message_open, tile_storage)
        self.assertLess(app_message_open, tile_decode_scratch)
        self.assertLess(app_message_open, tile_configuration)
        self.assertIn("app_message_result != APP_MSG_OK", main_source)

        header = (
            ROOT / "apps" / "pebble-watch" / "src" / "c" / "mappy.h"
        ).read_text(encoding="utf-8")
        decode = (
            ROOT / "apps" / "pebble-watch" / "src" / "c" / "tile_decode.c"
        ).read_text(encoding="utf-8")
        requests = (
            ROOT / "apps" / "pebble-watch" / "src" / "c" / "tile_requests.c"
        ).read_text(encoding="utf-8")
        self.assertIn("TILE_STORAGE_ARENA_BYTES (46 * 1024)", header)
        self.assertNotIn("s_tile_chunk_buffer", header + decode)
        self.assertIn("s_tile_chunk_store_packed", decode)
        self.assertIn("storage_suppressed", requests)

    def test_fixture_startup_honors_phone_ready_delay(self) -> None:
        fixture = (
            ROOT / "tooling" / "pebble-map-mock-pkjs.js"
        ).read_text(encoding="utf-8")
        generator = GENERATOR_PATH.read_text(encoding="utf-8")
        self.assertIn(
            "if (!ignoreStartupReady) setTimeout(sendReadyState, phoneReadyDelayMs);",
            fixture,
        )
        self.assertIn(
            "positiveModulo(tileColumn, 4) === 0",
            fixture,
        )
        self.assertIn(
            "positiveModulo(tileRow, 3) === 0",
            fixture,
        )
        self.assertIn("offset += tileChunkBytes", fixture)
        self.assertIn("'tile-he-'", fixture)
        feedback_echo = (
            "button_id: feedbackMode(pick(payload, 'button_id', KEY_BUTTON_ID))"
        )
        for source in (fixture, generator):
            self.assertIn(feedback_echo, source)
            self.assertIn(
                "mode === 0 || mode === 1 || mode === 2 || mode === 3 ? mode : 3",
                source,
            )

    def test_shell_scripts_parse_and_help_lists_supported_commands(self) -> None:
        helper = ROOT / "tooling" / "pebble-emulator-codex.sh"
        bootstrap = ROOT / "tooling" / "bootstrap-pebble-sdk-wsl.sh"
        for script in (helper, bootstrap):
            subprocess.run(["bash", "-n", str(script)], check=True)

        result = subprocess.run(
            ["bash", str(helper), "--help"],
            check=True,
            capture_output=True,
            text=True,
        )
        for command in (
            "doctor",
            "test-tooling",
            "test-protocol",
            "test-motion-host",
            "test-pan-inertia-host",
            "test-tile-cache-host",
            "test-tile-scheduler-host",
            "test-face-forward-render-host",
            "test-face-forward-angles",
            "test-render-performance",
            "test-pan-under-load",
            "test-rapid-zoom-reversal",
            "test-motion-reacquire",
            "build-phone",
            "capture-fixture",
            "capture-real-fixture",
            "smoke-fixture",
            "generate-real-fixture",
            "record-fixture-animation",
            "debug-facing",
            "debug-manual-browse",
            "debug-location-position",
            "debug-recenter",
            "debug-motion",
            "debug-route-progress",
            "kill",
        ):
            self.assertIn(command, result.stdout)

        helper_text = helper.read_text(encoding="utf-8")
        self.assertIn("test_pan_inertia_host", helper_text)
        self.assertIn("test_tile_scheduler_host", helper_text)
        self.assertIn("test_rapid_zoom_reversal", helper_text)
        self.assertTrue((ROOT / "tooling" / "test-pan-inertia.c").is_file())
        self.assertTrue((ROOT / "tooling" / "test-tile-request-scheduler.c").is_file())
        self.assertIn('PEBBLE_QEMU_CAPTURE_FRAMES:-60', helper_text)
        self.assertIn('PEBBLE_QEMU_CAPTURE_INTERVAL:-0.2', helper_text)
        for fixture_name in ("stationary-raise.csv", "walking-to-look.csv"):
            fixture = ROOT / "tooling" / "motion-fixtures" / fixture_name
            self.assertTrue(fixture.is_file())
            self.assertGreater(fixture.stat().st_size, 0)

    def test_windows_wrapper_forwards_paths_commands_and_arguments(self) -> None:
        wrapper = (ROOT / "tooling" / "pebble-wsl.ps1").read_text(encoding="utf-8")
        self.assertIn("--exec wslpath", wrapper)
        self.assertIn("--exec bash", wrapper)
        self.assertIn("$Command @CommandArgs", wrapper)

    def test_repository_skill_is_complete_and_documented(self) -> None:
        skill = (ROOT / ".agents" / "skills" / "pebble-emulator" / "SKILL.md").read_text(
            encoding="utf-8"
        )
        readme = (ROOT / "apps" / "pebble-watch" / "README.md").read_text(encoding="utf-8")
        metadata = (
            ROOT / ".agents" / "skills" / "pebble-emulator" / "agents" / "openai.yaml"
        ).read_text(encoding="utf-8")
        ignore_rules = (ROOT / ".gitignore").read_text(encoding="utf-8")
        self.assertNotIn("TODO", skill)
        self.assertIn("name: pebble-emulator", skill)
        self.assertIn("$pebble-emulator", metadata)
        self.assertIn("!.agents/skills/pebble-emulator/**", ignore_rules)
        self.assertIn(".agents/skills/pebble-emulator/SKILL.md", readme)
        self.assertNotIn(".codex/skills/pebble-watchface", readme)


if __name__ == "__main__":
    unittest.main(verbosity=2)
