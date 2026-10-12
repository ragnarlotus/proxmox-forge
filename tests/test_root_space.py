#!/usr/bin/env python3
"""F064: root filesystem space checks using the real helper and a fake pct."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RootSpaceTests(unittest.TestCase):
    def invoke(self, target, threshold, value=None, df_output=None, pct_failure=False):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            guard = root / "guard.sh"
            guard.write_text("#!/bin/bash\nexit 0\n")
            pct = root / "pct"
            pct.write_text(
                '#!/bin/bash\n'
                '[[ "$1" == exec && "$2" == 111 && "$3" == -- && "$4" == df && "$5" == -Pk && "$6" == / ]] || exit 90\n'
                '[[ "${FORGE_TEST_PCT_FAILURE:-0}" == 0 ]] || exit 73\n'
                'printf "%s" "$FORGE_TEST_DF_OUTPUT"\n')
            pct.chmod(0o755)
            env = dict(os.environ)
            env.update({
                "FORGE_RUNTIME_GUARD": str(guard),
                "FORGE_TEST_PCT_FAILURE": "1" if pct_failure else "0",
                "FORGE_TEST_DF_OUTPUT": df_output if df_output is not None else
                    "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 5000000 3951424 1048576 80% /\n",
                "PATH": f"{root}:{env['PATH']}",
            })
            cmd = ["bash", str(ROOT / "lib/preflight/root-space.sh"), str(target), str(threshold)]
            if value is not None:
                cmd.append(str(value))
            return subprocess.run(cmd, env=env, capture_output=True, text=True, check=False)

    def test_lxc_at_threshold_passes(self):
        result = self.invoke("111", 1024)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("space=ok target=111 free_kb=1048576", result.stdout)

    def test_insufficient_space_fails(self):
        result = self.invoke("111", 1024, "1048575")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("insufficient free space", result.stderr)

    def test_host_reuses_measurement(self):
        result = self.invoke("host", 1024, "2097152")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_measurement_fails_closed(self):
        for value in ("unknown", "-1", "123K", ""):
            with self.subTest(value=value):
                result = self.invoke("111", 1024, value)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("invalid root filesystem free-space value", result.stderr)

    def test_pct_failure_fails_closed(self):
        result = self.invoke("111", 1024, pct_failure=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not inspect root filesystem space", result.stderr)

    def test_invalid_df_output_fails_closed(self):
        result = self.invoke("111", 1024, df_output="bad output\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid root filesystem free-space value", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
