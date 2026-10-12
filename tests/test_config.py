#!/usr/bin/env python3
"""F209: isolated tests of Forge's real configuration loader and validator."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = ROOT / "forge.conf.default"

# Source the actual production config modules. The stub guard only replaces
# the Proxmox runtime/lock requirement, which these read-only unit tests do
# not exercise. There is no mock configuration parser or validator.
CONFIG_PROBE = r"""
source "$1/lib/config/get.sh" || exit 1
config_get_files "$2" "$3" || exit 1
printf 'BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=%s\n' "${CONFIG[BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE]}"
printf 'UPDATE_HOST=%s\n' "${CONFIG[UPDATE_HOST]}"
printf 'EXCLUDE=%s\n' "${CONFIG[EXCLUDE]}"
printf 'MIN_ROOT_FREE_MB=%s\n' "${CONFIG[MIN_ROOT_FREE_MB]}"
printf 'MIN_MEM_AVAILABLE_MB=%s\n' "${CONFIG[MIN_MEM_AVAILABLE_MB]}"
printf 'LOG_KEEP=%s\n' "${CONFIG[LOG_KEEP]}"
printf 'HOST_BACKUP_EXTRA_PATHS=%s\n' "${CONFIG[HOST_BACKUP_EXTRA_PATHS]}"
"""


class ConfigurationTests(unittest.TestCase):
    def load(self, override=None, defaults=None):
        with tempfile.TemporaryDirectory(prefix="forge-config-test-") as work:
            directory = Path(work)
            guard = directory / "test-guard.sh"
            guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")

            default_path = DEFAULTS
            if defaults is not None:
                default_path = directory / "forge.conf.default"
                default_path.write_text(defaults, encoding="utf-8")

            override_path = directory / "forge.conf"
            if override is not None:
                override_path.write_text(override, encoding="utf-8")

            environment = os.environ.copy()
            environment["FORGE_RUNTIME_GUARD"] = str(guard)
            environment.pop("FORGE_RUNTIME_CONFIG_READY", None)

            return subprocess.run(
                ["bash", "-c", CONFIG_PROBE, "forge-config-test",
                 str(ROOT), str(default_path), str(override_path)],
                capture_output=True,
                text=True,
                check=False,
                env=environment,
                cwd=ROOT,
            )

    def assert_invalid(self, override, error, defaults=None):
        result = self.load(override, defaults)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(error, result.stderr)

    def test_defaults_without_local_file(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true\n", result.stdout)
        self.assertIn("UPDATE_HOST=true\n", result.stdout)
        self.assertIn("EXCLUDE=\n", result.stdout)
        self.assertIn("MIN_ROOT_FREE_MB=1024\n", result.stdout)
        self.assertIn("MIN_MEM_AVAILABLE_MB=128\n", result.stdout)
        self.assertIn("LOG_KEEP=8\n", result.stdout)

    def test_local_overrides_defaults(self):
        result = self.load(
            'UPDATE_HOST=false\nLOG_KEEP=12\n'
            'BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=false\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UPDATE_HOST=false\n", result.stdout)
        self.assertIn("LOG_KEEP=12\n", result.stdout)
        self.assertIn("BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=false\n", result.stdout)

    def test_free_space_threshold_validation(self):
        result = self.load("MIN_ROOT_FREE_MB=512\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MIN_ROOT_FREE_MB=512\n", result.stdout)
        for invalid in ("0", "-1", "1.5", "not-a-number", "1048577"):
            with self.subTest(invalid=invalid):
                self.assert_invalid(f"MIN_ROOT_FREE_MB={invalid}\n", "MIN_ROOT_FREE_MB")

    def test_available_memory_threshold_validation(self):
        result = self.load("MIN_MEM_AVAILABLE_MB=256\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MIN_MEM_AVAILABLE_MB=256\n", result.stdout)
        for invalid in ("0", "-1", "1.5", "abc", "1048577"):
            with self.subTest(invalid=invalid):
                self.assert_invalid(f"MIN_MEM_AVAILABLE_MB={invalid}\n", "MIN_MEM_AVAILABLE_MB")

    def test_exclusions_allow_exact_ids_and_names(self):
        result = self.load('EXCLUDE=" 108, share, web.service-1 "\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("EXCLUDE= 108, share, web.service-1 \n", result.stdout)
        empty = self.load('EXCLUDE=""\n')
        self.assertEqual(empty.returncode, 0, empty.stderr)

    def test_exclusions_reject_invalid_entries(self):
        for value in ("100,", ",100", "100,,111", "100,   ,111",
                      "*", "share*", "bad name", "111;rm", "100/101"):
            with self.subTest(value=value):
                self.assert_invalid(f'EXCLUDE="{value}"\n', "EXCLUDE")

    def test_quoted_valid_values(self):
        result = self.load(
            'HOST_BACKUP_EXTRA_PATHS="/opt/custom,/srv/config"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            "HOST_BACKUP_EXTRA_PATHS=/opt/custom,/srv/config\n",
            result.stdout,
        )

    def test_unknown_key_rejected(self):
        self.assert_invalid("UNSUPPORTED_OPTION=true\n", "unknown configuration key")

    def test_duplicate_local_key_rejected(self):
        self.assert_invalid(
            "UPDATE_HOST=true\nUPDATE_HOST=false\n",
            "duplicate configuration key",
        )

    def test_duplicate_default_key_rejected(self):
        self.assert_invalid(
            None,
            "duplicate configuration key",
            DEFAULTS.read_text(encoding="utf-8") + "\nUPDATE_HOST=false\n",
        )

    def test_invalid_syntax_rejected(self):
        for line in ("update_host=true\n", "UPDATE_HOST =true\n",
                     "not-an-assignment\n", "UPDATE_HOST=true # comment\n"):
            with self.subTest(line=line):
                self.assert_invalid(line, "ERROR:")

    def test_invalid_booleans_rejected(self):
        for key in ("UPDATE_HOST", "BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE",
                    "ROLLBACK_ON_FAILURE", "CREATE_BACKUP_BEFORE_LXC_UPDATE"):
            with self.subTest(key=key):
                self.assert_invalid(f"{key}=yes\n", f"{key} must be true or false")

    def test_missing_required_key_rejected(self):
        original = DEFAULTS.read_text(encoding="utf-8")
        modified = original.replace(
            "BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true\n", ""
        )
        self.assertNotEqual(modified, original)
        self.assert_invalid(
            None, "missing required configuration key 'BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE'",
            modified,
        )

    def test_log_retention_requires_positive_integer(self):
        for value in ("0", "-1", "abc", "1.5"):
            with self.subTest(value=value):
                self.assert_invalid(f"LOG_KEEP={value}\n",
                                    "LOG_KEEP must be a positive integer")

    def test_paths_must_be_absolute(self):
        for key in ("CUSTOM_SCRIPTS_DIR", "LOG_DIR"):
            with self.subTest(key=key):
                self.assert_invalid(f'{key}="relative/path"\n',
                                    f"{key} must be an absolute path")

    def test_extra_backup_paths_must_be_valid(self):
        for value in ("relative", "/opt/custom,relative", ",/opt/custom",
                      "/opt/custom,", "/opt/custom,,/srv/config"):
            with self.subTest(value=value):
                self.assert_invalid(
                    f'HOST_BACKUP_EXTRA_PATHS="{value}"\n',
                    "HOST_BACKUP_EXTRA_PATHS",
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
