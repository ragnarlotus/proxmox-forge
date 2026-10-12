#!/usr/bin/env python3
"""F066: exercise real available-memory preflight with fake pct, without Proxmox mutation."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class MemoryPreflightTests(unittest.TestCase):
    def invoke(self, target, threshold, value=None, guest_value="262144",
               pct_failure=False):
        with tempfile.TemporaryDirectory(prefix="forge-memory-") as tmp:
            root = Path(tmp)
            guard = root / "guard.sh"
            guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            pct = root / "pct"
            pct.write_text(
                '#!/bin/bash\n'
                '[[ "$1" == exec && "$2" == 111 && "$3" == -- && "$4" == awk '
                '&& "$5" == *MemAvailable:* && "$6" == /proc/meminfo ]] || exit 90\n'
                '[[ "$FORGE_TEST_PCT_FAILURE" == 0 ]] || exit 73\n'
                'printf "%s\\n" "$FORGE_TEST_MEMORY_KB"\n',
                encoding="utf-8",
            )
            pct.chmod(0o755)
            env = {
                **os.environ,
                "FORGE_RUNTIME_GUARD": str(guard),
                "PATH": f"{root}:{os.environ['PATH']}",
                "FORGE_TEST_MEMORY_KB": guest_value,
                "FORGE_TEST_PCT_FAILURE": "1" if pct_failure else "0",
            }
            cmd = ["bash", str(ROOT / "lib/preflight/memory.sh"),
                   str(target), str(threshold)]
            if value is not None:
                cmd.append(str(value))
            return subprocess.run(cmd, capture_output=True, text=True,
                                  env=env, check=False)

    def test_guest_memory_at_threshold_succeeds(self):
        result = self.invoke("111", 128, guest_value="131072")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("memory=ok target=111 available_kb=131072", result.stdout)

    def test_guest_low_memory_fails(self):
        result = self.invoke("111", 128, guest_value="131071")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("insufficient available memory", result.stderr)

    def test_host_reuses_existing_measurement(self):
        result = self.invoke("host", 128, value="262144")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("memory=ok target=host", result.stdout)

    def test_invalid_memory_fails_closed(self):
        for value in ("unknown", "-1", "1.5", "", "12MB"):
            with self.subTest(value=value):
                result = self.invoke("111", 128, value=value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid available-memory value", result.stderr)

    def test_guest_inspection_failure_blocks(self):
        result = self.invoke("111", 128, pct_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not inspect available memory", result.stderr)

    def test_missing_memavailable_blocks(self):
        result = self.invoke("111", 128, guest_value="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid available-memory value", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
