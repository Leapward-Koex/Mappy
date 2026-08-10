#!/usr/bin/env python3
"""Regression checks for the repository Pebble development workflow."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
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
            "test-render-performance",
            "build-phone",
            "capture-fixture",
            "capture-real-fixture",
            "smoke-fixture",
            "generate-real-fixture",
            "record-fixture-animation",
            "debug-facing",
            "debug-route-progress",
            "kill",
        ):
            self.assertIn(command, result.stdout)

        helper_text = helper.read_text(encoding="utf-8")
        self.assertIn('PEBBLE_QEMU_CAPTURE_FRAMES:-60', helper_text)
        self.assertIn('PEBBLE_QEMU_CAPTURE_INTERVAL:-0.2', helper_text)

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
