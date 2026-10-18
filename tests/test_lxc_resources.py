#!/usr/bin/env python3
"""F234: exercise actual LXC resource helper with fake Proxmox pct operations."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "lib/lxc/resources.sh"

FAKE_PCT = r"""#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
config=Path(os.environ["FORGE_TEST_RESOURCE_CONFIG"])
calls=Path(os.environ["FORGE_TEST_RESOURCE_CALLS"])
with calls.open("a") as handle:
    handle.write(json.dumps(args)+"\n")
values=json.loads(config.read_text())
if args[:2]==["config","111"] and args[2:]==["--current","1"]:
    for name in ("cores","memory","cpulimit","swap"):
        if name in values:
            print(f"{name}: {values[name]}")
elif args[:2]==["set","111"]:
    pairs=args[2:]
    if len(pairs)%2:
        sys.exit(91)
    for i in range(0,len(pairs),2):
        if pairs[i] not in ("--cores","--memory"):
            sys.exit(92)
        values[pairs[i][2:]]=int(pairs[i+1])
        if os.environ.get("FORGE_TEST_PARTIAL_SET")=="true" and not Path(
            os.environ["FORGE_TEST_PARTIAL_MARKER"]).exists():
            config.write_text(json.dumps(values))
            Path(os.environ["FORGE_TEST_PARTIAL_MARKER"]).touch()
            sys.exit(42)
    config.write_text(json.dumps(values))
else:
    print(f"unexpected pct invocation: {args}",file=sys.stderr)
    sys.exit(93)
"""


class ResourceTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="forge-f234-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        binary = self.root / "bin"
        binary.mkdir()
        pct = binary / "pct"
        pct.write_text(FAKE_PCT)
        pct.chmod(0o755)
        guard = self.root / "guard.sh"
        guard.write_text("#!/bin/sh\nexit 0\n")
        self.state = self.root / "saved.state"
        self.state.touch()
        self.config = self.root / "guest.json"
        self.config.write_text(json.dumps({"cores": 1, "memory": 512,
                                           "cpulimit": 0.5, "swap": 128}))
        self.calls = self.root / "pct-calls"
        self.env = {
            **os.environ,
            "FORGE_RUNTIME_GUARD": str(guard),
            "PATH": f"{binary}:{os.environ['PATH']}",
            "FORGE_TEST_RESOURCE_CONFIG": str(self.config),
            "FORGE_TEST_RESOURCE_CALLS": str(self.calls),
            "FORGE_TEST_PARTIAL_MARKER": str(self.root / "partial-marker"),
        }

    def run_resource(self, operation, *args, **env):
        return subprocess.run(
            ["bash", str(SCRIPT), operation, "111", str(self.state), *map(str, args)],
            capture_output=True, text=True, check=False, env={**self.env, **env},
        )

    def guest(self):
        return json.loads(self.config.read_text())

    def pct_calls(self):
        return [json.loads(x) for x in self.calls.read_text().splitlines()]

    def test_apply_and_restore_both_limits(self):
        result = self.run_resource("apply", 2, 1024, 128)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.guest(), {"cores": 2, "memory": 1024,
                                        "cpulimit": 0.5, "swap": 128})
        self.assertIn(["set", "111", "--cores", "2", "--memory", "1024"],
                      self.pct_calls())
        result = self.run_resource("restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.guest(), {"cores": 1, "memory": 512,
                                        "cpulimit": 0.5, "swap": 128})
        self.assertEqual(self.state.read_text(), "")
        self.assertEqual(self.pct_calls().count(
            ["set", "111", "--cores", "1", "--memory", "512"]), 1)

    def test_noop_when_limits_already_sufficient(self):
        result = self.run_resource("apply", 1, 256, 128)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("resources=skipped", result.stdout)
        self.assertEqual(self.state.read_text(), "")
        self.assertFalse(any(x[0] == "set" for x in self.pct_calls()))

    def test_partial_pct_failure_is_restorable(self):
        result = self.run_resource("apply", 2, 1024, 128,
                                   FORGE_TEST_PARTIAL_SET="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.state.read_text())
        self.assertEqual(self.guest()["cores"], 2)
        result = self.run_resource("restore")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.guest()["cores"], 1)
        self.assertEqual(self.guest()["memory"], 512)

    def test_external_change_is_never_overwritten(self):
        result = self.run_resource("apply", 2, 1024, 128)
        self.assertEqual(result.returncode, 0, result.stderr)
        values = self.guest()
        values["memory"] = 1500
        self.config.write_text(json.dumps(values))
        result = self.run_resource("restore")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("changed externally", result.stderr)
        self.assertEqual(self.guest()["memory"], 1500)
        self.assertTrue(self.state.read_text())

    def test_insufficient_host_headroom_blocks_before_pct_set(self):
        result = self.run_resource("apply", 0, 1048576, 1048576)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("host available memory", result.stderr)
        self.assertFalse(any(x[0] == "set" for x in self.pct_calls()))

    def test_missing_original_limit_blocks_instead_of_guessing(self):
        self.config.write_text(json.dumps({"memory": 512}))
        result = self.run_resource("apply", 2, 0, 128)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no explicit cores limit", result.stderr)
        self.assertEqual(self.state.read_text(), "")
        self.assertFalse(any(x[0] == "set" for x in self.pct_calls()))


if __name__ == "__main__":
    unittest.main()
