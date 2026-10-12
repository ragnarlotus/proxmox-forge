#!/usr/bin/env python3
"""F206: verify that real Forge stages preserve the original operation's exit code."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# The only external Proxmox executable available to stage tests is this fake
# pct. It never changes a container; for custom scripts, it executes only the
# temporary test script passed on stdin.
MOCK_PCT = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
if args[:3] != ["exec", "111", "--"]:
    print(f"unexpected pct call: {args}", file=sys.stderr)
    sys.exit(97)

if "apt-get" in args:
    operation = next(
        (name for name in ("update", "dist-upgrade", "autoremove")
         if name in args[args.index("apt-get") + 1:]), None,
    )
elif "/usr/bin/update" in args:
    operation = "application"
elif args[-3:] == ["bash", "-s", "--"]:
    operation = "custom"
else:
    operation = None

if operation is None:
    print(f"unexpected pct command: {args}", file=sys.stderr)
    sys.exit(98)

with Path(os.environ["FORGE_TEST_CALLS"]).open("a") as calls:
    calls.write(json.dumps(operation) + "\n")

if operation == "custom":
    sys.exit(subprocess.run(
        ["bash", "-s", "--"], input=sys.stdin.read(), text=True, check=False
    ).returncode)

print("FAKE_STDOUT " + operation)
print("FAKE_STDERR " + operation, file=sys.stderr)
sys.exit(json.loads(os.environ.get("FORGE_TEST_EXIT_CODES", "{}")).get(operation, 0))
"""


class ExitCodeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-exit-codes-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin_dir = self.directory / "bin"
        self.bin_dir.mkdir()
        mock = self.bin_dir / "pct"
        mock.write_text(MOCK_PCT, encoding="utf-8")
        mock.chmod(0o755)

        guard = self.directory / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.calls_file = self.directory / "calls.jsonl"
        self.log_file = self.directory / "stage.log"
        self.log_file.touch()

        self.env = os.environ.copy()
        self.env.update({
            "PATH": f"{self.bin_dir}:{self.env['PATH']}",
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_CALLS": str(self.calls_file),
        })

    def execute(self, path, *args):
        return subprocess.run(
            ["bash", str(ROOT / path), *args],
            env=self.env, cwd=ROOT, capture_output=True, text=True, check=False,
        )

    def calls(self):
        if not self.calls_file.exists():
            return []
        return [json.loads(v) for v in self.calls_file.read_text().splitlines()]

    def test_capture_preserves_failure_status_and_output(self):
        result = self.execute(
            "lib/logging/capture.sh", str(self.log_file), "test_failure", "--",
            "bash", "-c", "printf 'stdout-marker\\n'; printf 'stderr-marker\\n' >&2; exit 42",
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("stdout-marker", result.stdout)
        self.assertIn("stderr-marker", result.stdout)
        log = self.log_file.read_text()
        self.assertIn("stdout-marker", log)
        self.assertIn("stderr-marker", log)
        self.assertIn("stage=test_failure", log)
        self.assertIn("status=failed", log)
        self.assertIn("exit_code=42", log)

    def test_capture_reports_success_without_changing_exit_code(self):
        result = self.execute(
            "lib/logging/capture.sh", str(self.log_file), "test_success", "--",
            "bash", "-c", "printf 'success-marker\\n'; exit 0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("success-marker", result.stdout)
        self.assertIn("status=success", self.log_file.read_text())
        self.assertIn("exit_code=0", self.log_file.read_text())

    def test_os_update_preserves_failure_at_each_apt_stage(self):
        for failed, code, expected_calls in (
            ("update", 17, ["update"]),
            ("dist-upgrade", 23, ["update", "dist-upgrade"]),
            ("autoremove", 31, ["update", "dist-upgrade", "autoremove"]),
        ):
            with self.subTest(failed=failed):
                self.calls_file.write_text("")
                self.env["FORGE_TEST_EXIT_CODES"] = json.dumps({failed: code})
                result = self.execute("lib/lxc/update/os.sh", "111", "apt")
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertEqual(self.calls(), expected_calls)
                self.assertIn(f"exit code: {code}", result.stderr)
                self.assertNotIn("os_update=success", result.stdout)

    def test_os_update_success(self):
        result = self.execute("lib/lxc/update/os.sh", "111", "apt")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["update", "dist-upgrade", "autoremove"])
        self.assertIn("os_update=success", result.stdout)

    def test_application_failure_exit_code(self):
        self.env["FORGE_TEST_EXIT_CODES"] = json.dumps({"application": 42})
        result = self.execute(
            "lib/lxc/update/application.sh", "111", "/usr/bin/update"
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.calls(), ["application"])
        self.assertIn("exit code: 42", result.stderr)
        self.assertNotIn("application_update=success", result.stdout)

    def test_application_success(self):
        result = self.execute(
            "lib/lxc/update/application.sh", "111", "/usr/bin/update"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["application"])
        self.assertIn("application_update=success", result.stdout)

    def test_custom_script_failure_preserves_code_and_stops(self):
        target_dir = self.directory / "scripts.d" / "111"
        target_dir.mkdir(parents=True)
        (target_dir / "01-fail.sh").write_text(
            "printf 'script-marker\\n'\nexit 42\n", encoding="utf-8"
        )
        (target_dir / "02-must-not-run.sh").write_text(
            "printf 'unexpected-script\\n'\nexit 0\n", encoding="utf-8"
        )
        result = self.execute(
            "lib/lxc/update/custom-scripts.sh", "111",
            str(self.directory / "scripts.d"),
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(self.calls(), ["custom"])
        self.assertIn("script-marker", result.stdout)
        self.assertNotIn("unexpected-script", result.stdout)
        self.assertIn("exit code: 42", result.stderr)

    def test_custom_scripts_success(self):
        target_dir = self.directory / "scripts.d" / "111"
        target_dir.mkdir(parents=True)
        for i in (1, 2):
            (target_dir / f"0{i}-ok.sh").write_text(
                f"printf 'script-{i}\\n'\nexit 0\n", encoding="utf-8"
            )
        result = self.execute(
            "lib/lxc/update/custom-scripts.sh", "111",
            str(self.directory / "scripts.d"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls(), ["custom", "custom"])
        self.assertIn("custom_scripts=success vmid=111 count=2", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
