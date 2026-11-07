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
printf 'CREATE_BACKUP_BEFORE_LXC_UPDATE=%s\n' "${CONFIG[CREATE_BACKUP_BEFORE_LXC_UPDATE]}"
printf 'UPDATE_HOST=%s\n' "${CONFIG[UPDATE_HOST]}"
printf 'EMAIL_NOTIFICATIONS=%s\n' "${CONFIG[EMAIL_NOTIFICATIONS]}"
printf 'NOTIFY_MANUAL=%s\n' "${CONFIG[NOTIFY_MANUAL]}"
printf 'NOTIFY_SCHEDULED=%s\n' "${CONFIG[NOTIFY_SCHEDULED]}"
printf 'CHECK_FORGE_UPDATES_BEFORE_UPDATE=%s\n' "${CONFIG[CHECK_FORGE_UPDATES_BEFORE_UPDATE]}"
printf 'PERSISTENT_UPDATE_SESSION=%s\n' "${CONFIG[PERSISTENT_UPDATE_SESSION]}"
printf 'SCHEDULED_UPDATE_HOST=%s\n' "${CONFIG[SCHEDULED_UPDATE_HOST]}"
printf 'SCHEDULED_UPDATE_LXC=%s\n' "${CONFIG[SCHEDULED_UPDATE_LXC]}"
printf 'EXCLUDE=%s\n' "${CONFIG[EXCLUDE]}"
printf 'MIN_ROOT_FREE_MB=%s\n' "${CONFIG[MIN_ROOT_FREE_MB]}"
printf 'HEALTH_SCRIPTS_DIR=%s\n' "${CONFIG[HEALTH_SCRIPTS_DIR]}"
printf 'MIN_MEM_AVAILABLE_MB=%s\n' "${CONFIG[MIN_MEM_AVAILABLE_MB]}"
printf 'LXC_UPDATE_TEMP_CORES=%s\n' "${CONFIG[LXC_UPDATE_TEMP_CORES]}"
printf 'LXC_UPDATE_TEMP_MEMORY_MB=%s\n' "${CONFIG[LXC_UPDATE_TEMP_MEMORY_MB]}"
printf 'LOG_KEEP=%s\n' "${CONFIG[LOG_KEEP]}"
printf 'LANGUAGE=%s\n' "${CONFIG[LANGUAGE]}"
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

    def test_language_validation_and_local_override(self):
        result = self.load("LANGUAGE=es\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LANGUAGE=es\n", result.stdout)
        for value in ("", "ES", "fr", "de", "auto", "../es", "en_US"):
            self.assert_invalid(f"LANGUAGE={value}\n", "LANGUAGE must be en or es")

    def test_defaults_without_local_file(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CREATE_BACKUP_BEFORE_LXC_UPDATE=true\n", result.stdout)
        self.assertIn("UPDATE_HOST=true\n", result.stdout)
        self.assertIn("EMAIL_NOTIFICATIONS=false\n", result.stdout)
        self.assertIn("NOTIFY_MANUAL=errors\n", result.stdout)
        self.assertIn("NOTIFY_SCHEDULED=all\n", result.stdout)
        self.assertIn("EXCLUDE=\n", result.stdout)
        self.assertIn("MIN_ROOT_FREE_MB=1024\n", result.stdout)
        self.assertIn("MIN_MEM_AVAILABLE_MB=128\n", result.stdout)
        self.assertIn("LOG_KEEP=8\n", result.stdout)
        self.assertIn("LANGUAGE=en\n", result.stdout)
        self.assertIn("HEALTH_SCRIPTS_DIR=/opt/proxmox-forge/health.d\n", result.stdout)

    def test_local_overrides_defaults(self):
        result = self.load(
            'UPDATE_HOST=false\nLOG_KEEP=12\n'
            'CREATE_BACKUP_BEFORE_LXC_UPDATE=false\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("UPDATE_HOST=false\n", result.stdout)
        self.assertIn("LOG_KEEP=12\n", result.stdout)
        self.assertIn("CREATE_BACKUP_BEFORE_LXC_UPDATE=false\n", result.stdout)

    def test_notification_policies_and_validation(self):
        for manual in ("none", "errors", "all"):
            for scheduled in ("none", "errors", "all"):
                with self.subTest(manual=manual, scheduled=scheduled):
                    result = self.load(
                        "EMAIL_NOTIFICATIONS=true\n"
                        f"NOTIFY_MANUAL={manual}\nNOTIFY_SCHEDULED={scheduled}\n"
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("EMAIL_NOTIFICATIONS=true\n", result.stdout)
                    self.assertIn(f"NOTIFY_MANUAL={manual}\n", result.stdout)
                    self.assertIn(f"NOTIFY_SCHEDULED={scheduled}\n", result.stdout)
        self.assert_invalid("EMAIL_NOTIFICATIONS=yes\n",
                            "EMAIL_NOTIFICATIONS must be true or false")
        for key in ("NOTIFY_MANUAL", "NOTIFY_SCHEDULED"):
            for value in ("", "true", "inherit", "ERRORS", "all,errors", "yes"):
                with self.subTest(key=key, value=value):
                    self.assert_invalid(f"{key}={value}\n",
                                        f"{key} must be none, errors or all")
        self.assert_invalid("NOTIFY_ONLY_ERRORS=false\n",
                            "unknown configuration key 'NOTIFY_ONLY_ERRORS'")

    def test_f238_prompt_is_default_on_and_can_be_disabled(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CHECK_FORGE_UPDATES_BEFORE_UPDATE=true\n", result.stdout)
        result = self.load("CHECK_FORGE_UPDATES_BEFORE_UPDATE=false\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CHECK_FORGE_UPDATES_BEFORE_UPDATE=false\n", result.stdout)
        self.assert_invalid("CHECK_FORGE_UPDATES_BEFORE_UPDATE=yes\n",
                            "CHECK_FORGE_UPDATES_BEFORE_UPDATE")

    def test_f131_opt_in_is_validated_and_defaults_off(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PERSISTENT_UPDATE_SESSION=false", result.stdout)
        result = self.load("PERSISTENT_UPDATE_SESSION=true\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PERSISTENT_UPDATE_SESSION=true", result.stdout)
        self.assert_invalid("PERSISTENT_UPDATE_SESSION=auto\n",
                            "PERSISTENT_UPDATE_SESSION must be true or false")

    def test_scheduled_defaults_are_fail_closed(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SCHEDULED_UPDATE_HOST=false\n", result.stdout)
        self.assertIn("SCHEDULED_UPDATE_LXC=\n", result.stdout)

    def test_scheduled_authorization_accepts_only_exact_distinct_vmids(self):
        result = self.load(
            'SCHEDULED_UPDATE_HOST=true\n'
            'SCHEDULED_UPDATE_LXC="100, 111, 115"\n'
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SCHEDULED_UPDATE_HOST=true\n", result.stdout)
        self.assertIn("SCHEDULED_UPDATE_LXC=100, 111, 115\n", result.stdout)
        self.assert_invalid("SCHEDULED_UPDATE_HOST=yes\n", "SCHEDULED_UPDATE_HOST")
        for value in ("100,", ",100", "100,,111", "100, ,111",
                      "100,100", "100, 100", "0100", "0", "-1", "guest100",
                      "100,guest111", "100-111", "*", "100;echo hi",
                      "100/111", "1234567890"):
            with self.subTest(value=value):
                self.assert_invalid(f'SCHEDULED_UPDATE_LXC="{value}"\n',
                                    "SCHEDULED_UPDATE_LXC")

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

    def test_temporary_resource_config(self):
        result = self.load()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LXC_UPDATE_TEMP_CORES=0\n", result.stdout)
        self.assertIn("LXC_UPDATE_TEMP_MEMORY_MB=0\n", result.stdout)
        result = self.load("LXC_UPDATE_TEMP_CORES=4\nLXC_UPDATE_TEMP_MEMORY_MB=4096\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LXC_UPDATE_TEMP_CORES=4\n", result.stdout)
        self.assertIn("LXC_UPDATE_TEMP_MEMORY_MB=4096\n", result.stdout)
        for key, invalids in (
            ("LXC_UPDATE_TEMP_CORES", ("-1", "01", "1.5", "foo", "8193")),
            ("LXC_UPDATE_TEMP_MEMORY_MB", ("-1", "01", "1.5", "foo", "1048577")),
        ):
            for value in invalids:
                with self.subTest(key=key, value=value):
                    self.assert_invalid(f"{key}={value}\n", key)

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

    def test_functional_health_directory_configuration(self):
        result = self.load('HEALTH_SCRIPTS_DIR="/srv/forge-health"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HEALTH_SCRIPTS_DIR=/srv/forge-health\n", result.stdout)
        self.assert_invalid('HEALTH_SCRIPTS_DIR="relative/dir"\n', "HEALTH_SCRIPTS_DIR")

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

    def test_obsolete_snapshot_fallback_setting_is_rejected(self):
        self.assert_invalid(
            "BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true\n",
            "unknown configuration key",
        )

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
        for key in ("UPDATE_HOST", "ROLLBACK_ON_FAILURE", "CREATE_BACKUP_BEFORE_LXC_UPDATE"):
            with self.subTest(key=key):
                self.assert_invalid(f"{key}=yes\n", f"{key} must be true or false")

    def test_missing_required_key_rejected(self):
        original = DEFAULTS.read_text(encoding="utf-8")
        modified = original.replace(
            "CREATE_BACKUP_BEFORE_LXC_UPDATE=true\n", ""
        )
        self.assertNotEqual(modified, original)
        self.assert_invalid(
            None, "missing required configuration key 'CREATE_BACKUP_BEFORE_LXC_UPDATE'",
            modified,
        )

    def test_log_retention_requires_positive_integer(self):
        for value in ("0", "-1", "abc", "1.5"):
            with self.subTest(value=value):
                self.assert_invalid(f"LOG_KEEP={value}\n",
                                    "LOG_KEEP must be a positive integer")

    def test_paths_must_be_absolute(self):
        for key in ("CUSTOM_SCRIPTS_DIR", "HEALTH_SCRIPTS_DIR", "LOG_DIR"):
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
