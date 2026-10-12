#!/usr/bin/env python3
"""F207: verify that the real Proxmox host APT updater invokes each command once."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APT_MOCK = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

args = sys.argv[1:]
stages = [v for v in ("update", "full-upgrade", "autoremove") if v in args]
if len(stages) != 1:
    print(f"unexpected apt-get arguments: {args}", file=sys.stderr)
    sys.exit(99)
stage = stages[0]
with Path(os.environ["FORGE_TEST_APT_CALLS"]).open("a") as stream:
    stream.write(json.dumps(stage) + "\n")
if stage == os.environ.get("FORGE_TEST_APT_FAILURE"):
    sys.exit(42)
"""


class HostExactlyOnceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-host-once-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin_dir = self.directory / "bin"
        self.bin_dir.mkdir()
        apt = self.bin_dir / "apt-get"
        apt.write_text(APT_MOCK, encoding="utf-8")
        apt.chmod(0o755)
        guard = self.directory / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.calls_path = self.directory / "calls.jsonl"
        self.env = os.environ.copy()
        self.env.update({
            "PATH": f"{self.bin_dir}:{self.env['PATH']}",
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_APT_CALLS": str(self.calls_path),
        })

    def run_update(self, failed_stage=None):
        env = self.env.copy()
        if failed_stage is not None:
            env["FORGE_TEST_APT_FAILURE"] = failed_stage
        else:
            env.pop("FORGE_TEST_APT_FAILURE", None)
        result = subprocess.run(
            ["bash", str(ROOT / "lib/host/update/os.sh")],
            env=env, cwd=ROOT, capture_output=True, text=True, check=False,
        )
        calls = [
            json.loads(line)
            for line in self.calls_path.read_text().splitlines()
        ] if self.calls_path.exists() else []
        return result, calls

    def test_host_apt_steps_each_run_once(self):
        result, calls = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ["update", "full-upgrade", "autoremove"])
        self.assertIn("host_os_update=success", result.stdout)

    def test_host_apt_failure_stops_without_retries(self):
        steps = ["update", "full-upgrade", "autoremove"]
        for stage in steps:
            with self.subTest(stage=stage):
                self.calls_path.unlink(missing_ok=True)
                result, calls = self.run_update(stage)
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertEqual(calls, steps[:steps.index(stage) + 1])
                self.assertNotIn("host_os_update=success", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
