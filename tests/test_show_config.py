#!/usr/bin/env python3
"""F180: test the actual Forge CLI show-config dispatch in an isolated checkout."""

import os
import re
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULTS = ROOT / "forge.conf.default"
LOCK_DEFAULT = 'LOCK_FILE="/run/lock/proxmox-forge.lock"'


class ShowConfigTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-show-config-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        checkout = self.directory / "checkout"
        checkout.mkdir()
        self.checkout = checkout
        self.config_path = checkout / "forge.conf"
        (checkout / "forge.conf.default").write_text(DEFAULTS.read_text(), encoding="utf-8")

        # Exercise the actual Forge CLI, not a duplicate dispatcher. Only the
        # global lock location is replaced with a private test path.
        cli = (ROOT / "forge").read_text(encoding="utf-8")
        self.assertIn(LOCK_DEFAULT, cli)
        cli = cli.replace(LOCK_DEFAULT, f'LOCK_FILE="{self.directory / "forge.lock"}"', 1)
        entry = checkout / "forge"
        entry.write_text(cli, encoding="utf-8")
        entry.chmod(0o755)

        for path in (
            "lib/runtime/require-context.sh",
            "lib/config/get.sh",
            "lib/config/load.sh",
            "lib/config/validate.sh",
            "lib/config/show.sh",
            "lib/cli/help.sh",
        ):
            target = checkout / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(ROOT / path)

        # Unexpected Proxmox probes would fail and be recorded. show-config
        # should not even reach these commands.
        bin_dir = self.directory / "bin"
        bin_dir.mkdir()
        self.proxmox_calls = self.directory / "unexpected-proxmox.txt"
        for name in ("pct", "pvesh", "pvesm"):
            binary = bin_dir / name
            binary.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"$0 $*\" >> \"$FORGE_TEST_PROXMOX_CALLS\"\n"
                "exit 99\n", encoding="utf-8",
            )
            binary.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update({
            "PATH": f"{bin_dir}:{self.env['PATH']}",
            "FORGE_TEST_PROXMOX_CALLS": str(self.proxmox_calls),
        })

    def run_forge(self, *args):
        result = subprocess.run(
            [str(self.checkout / "forge"), *args],
            cwd=self.checkout,
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertFalse(self.proxmox_calls.exists(), "show-config called Proxmox")
        return result

    def rows(self, result):
        parsed = {}
        for line in result.stdout.splitlines():
            match = re.fullmatch(r"([A-Z][A-Z0-9_]*)=(.*)  # source=(default|override)", line)
            self.assertIsNotNone(match, line)
            key, raw, origin = match.groups()
            self.assertNotIn(key, parsed)
            parsed[key] = (shlex.split("VALUE=" + raw)[0][6:], origin)
        return parsed

    def test_defaults_are_sorted_and_sourced(self):
        result = self.run_forge("show-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(result.stderr)
        rows = self.rows(result)
        self.assertEqual(list(rows), sorted(rows))
        self.assertEqual(rows["UPDATE_HOST"], ("true", "default"))
        self.assertEqual(rows["EXCLUDE"], ("", "default"))
        self.assertEqual(rows["HEALTH_SCRIPTS_DIR"],
                         ("/opt/proxmox-forge/health.d", "default"))
        self.assertTrue(all(origin == "default" for _, origin in rows.values()))

    def test_overrides_show_origin_even_when_same_as_default(self):
        self.config_path.write_text(
            'LOG_KEEP=12\nUPDATE_HOST=true\nEXCLUDE=" 108, share "\n',
            encoding="utf-8",
        )
        result = self.run_forge("show-config")
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows(result)
        self.assertEqual(rows["LOG_KEEP"], ("12", "override"))
        self.assertEqual(rows["UPDATE_HOST"], ("true", "override"))
        self.assertEqual(rows["EXCLUDE"], (" 108, share ", "override"))
        self.assertEqual(rows["MIN_ROOT_FREE_MB"], ("1024", "default"))

    def test_bad_config_has_no_effective_output(self):
        self.config_path.write_text("LOG_KEEP=-1\n", encoding="utf-8")
        result = self.run_forge("show-config")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LOG_KEEP", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_unknown_config_key_rejected(self):
        self.config_path.write_text("SOMETHING_ELSE=1\n", encoding="utf-8")
        result = self.run_forge("show-config")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown configuration key", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_arguments_rejected(self):
        result = self.run_forge("show-config", "--force")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not accept additional arguments", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_help_documents_command(self):
        result = self.run_forge("help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("show-config", result.stdout)

    def test_sensitive_values_are_redacted(self):
        # The current schema does not include a sensitive setting. Exercise the
        # real display helper directly with a synthetic future config key.
        guard = self.directory / "no-op-guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        command = r"""
declare -A CONFIG=([API_TOKEN]="not-for-output" [UPDATE_HOST]="true")
declare -A CONFIG_SOURCES=([API_TOKEN]="override" [UPDATE_HOST]="default")
source "$1" || exit 1
config_show
"""
        result = subprocess.run(
            ["bash", "-c", command, "_", str(ROOT / "lib/config/show.sh")],
            cwd=self.checkout, capture_output=True, text=True, check=False,
            env={**self.env, "FORGE_RUNTIME_GUARD": str(guard)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("API_TOKEN='<redacted>'  # source=override", result.stdout)
        self.assertNotIn("not-for-output", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
