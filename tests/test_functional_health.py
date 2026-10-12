#!/usr/bin/env python3
"""F101: real generic+functional health, with isolated Proxmox and config fakes."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

PCT_FAKE = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
with Path(os.environ["FORGE_TEST_PCT_CALLS"]).open("a") as out:
    out.write(json.dumps(args[:4]) + "\n")

if args[:3] != ["exec", "111", "--"]:
    sys.exit("unexpected pct invocation")
if args[3:5] == ["sh", "-c"]:
    print("systemd" if os.environ.get("FORGE_TEST_INIT") == "systemd" else "other")
elif args[3:] == ["systemctl", "--failed", "--type=service", "--no-legend",
                  "--no-pager", "--plain"]:
    if os.environ.get("FORGE_TEST_FAILED_SERVICES"):
        print("broken.service")
elif args[3:] == ["bash", "-s", "--"]:
    sys.exit(subprocess.run(
        ["bash", "-s", "--"], input=sys.stdin.read(), text=True, check=False,
    ).returncode)
else:
    sys.exit(f"unexpected pct arguments: {args}")
"""


class FunctionalHealthTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-f101-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        lxc = self.base / "lib" / "lxc"
        lxc.mkdir(parents=True)
        (lxc / "health.sh").symlink_to(ROOT / "lib/lxc/health.sh")
        (lxc / "health-scripts.sh").symlink_to(ROOT / "lib/lxc/health-scripts.sh")
        (lxc / "get-state.sh").write_text(
            '#!/bin/bash\nprintf "%s\\n" "$FORGE_TEST_STATE"\n', encoding="utf-8",
        )
        config = self.base / "lib" / "config"
        config.mkdir()
        (config / "get.sh").write_text(
            'config_get() { declare -gA CONFIG=(\n'
            '  [HEALTH_SCRIPTS_DIR]="$FORGE_TEST_HEALTH_DIR"\n'
            '); }\n', encoding="utf-8",
        )
        self.health_dir = self.base / "health.d"
        self.health_dir.mkdir()
        bindir = self.base / "bin"
        bindir.mkdir()
        fake = bindir / "pct"
        fake.write_text(PCT_FAKE, encoding="utf-8")
        fake.chmod(0o755)
        guard = self.base / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.calls_path = self.base / "pct.jsonl"
        self.env = {
            **os.environ,
            "PATH": f"{bindir}:{os.environ['PATH']}",
            "LC_ALL": "C",
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_PCT_CALLS": str(self.calls_path),
            "FORGE_TEST_HEALTH_DIR": str(self.health_dir),
            "FORGE_TEST_STATE": "running",
        }

    def script(self, name, data, vmid="111"):
        target = self.health_dir / vmid
        target.mkdir(exist_ok=True)
        file = target / name
        file.write_text(data, encoding="utf-8")
        return file

    def invoke(self, **extra):
        self.calls_path.unlink(missing_ok=True)
        result = subprocess.run(
            ["bash", str(self.base / "lib/lxc/health.sh"), "111"],
            cwd=self.base, env={**self.env, **extra},
            capture_output=True, text=True, check=False,
        )
        calls = ([json.loads(line) for line in self.calls_path.read_text().splitlines()]
                 if self.calls_path.exists() else [])
        return result, calls

    def test_missing_directory_keeps_generic_health(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("health=ok vmid=111", result.stdout)
        self.assertIn("functional_health=skipped vmid=111 reason=no_target_directory", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_empty_directory_skips_functional_checks(self):
        (self.health_dir / "111").mkdir()
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reason=no_scripts", result.stdout)
        self.assertEqual(len(calls), 1)

    def test_scripts_run_in_filename_order_after_generic_health(self):
        self.script("02-second.sh", "printf 'second\\n'\n")
        self.script("01-first.sh", "printf 'first\\n'\n")
        self.script("notes.txt", "printf 'never\\n'\n")
        self.script("03-backup.sh~", "printf 'never\\n'\n")
        result, calls = self.invoke(FORGE_TEST_INIT="systemd")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertLess(result.stdout.index("first"), result.stdout.index("second"))
        self.assertIn("functional_health=ok vmid=111 count=2", result.stdout)
        self.assertIn("systemd_services=clean", result.stdout)
        self.assertEqual(len(calls), 4, calls)
        self.assertEqual(calls[1][3], "systemctl")

    def test_nonzero_fails_and_stops_later_checks(self):
        self.script("01-fail.sh", "printf 'first\\n'\nexit 42\n")
        self.script("02-not-run.sh", "printf 'SHOULD_NOT_RUN\\n'\n")
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("exit code: 42", result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)
        self.assertNotIn("health=ok", result.stdout)
        self.assertEqual(len(calls), 2)

    def test_symlinks_and_nonregular_entries_are_ignored(self):
        self.script("01-valid.sh", "printf 'valid\\n'\n")
        target = self.health_dir / "111"
        (target / "02-link.sh").symlink_to(target / "01-valid.sh")
        (target / "03-directory.sh").mkdir()
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("functional_health=ok vmid=111 count=1", result.stdout)
        self.assertEqual(len(calls), 2)

    def test_generic_health_failure_blocks_custom_checks(self):
        self.script("01-not-run.sh", "printf 'SHOULD_NOT_RUN\\n'\n")
        result, calls = self.invoke(
            FORGE_TEST_INIT="systemd", FORGE_TEST_FAILED_SERVICES="yes",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed systemd services", result.stderr)
        self.assertNotIn("SHOULD_NOT_RUN", result.stdout)
        self.assertEqual(len(calls), 2)

    def test_not_running_blocks_custom_checks(self):
        self.script("01-not-run.sh", "printf 'SHOULD_NOT_RUN\\n'\n")
        result, calls = self.invoke(FORGE_TEST_STATE="stopped")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_existing_target_non_directory_fails_closed(self):
        (self.health_dir / "111").write_text("invalid\n", encoding="utf-8")
        result, calls = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a directory", result.stderr)

    def test_repeated_health_invocations_run_checks_each_time(self):
        self.script("01-check.sh", "printf 'checked\\n'\n")
        first, _ = self.invoke()
        second, _ = self.invoke()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first.stdout.count("checked"), 1)
        self.assertEqual(second.stdout.count("checked"), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
