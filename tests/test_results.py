#!/usr/bin/env python3
"""F211: exercise the real bulk coordinator with isolated host/LXC test doubles."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# Only update-all.sh is production code; all relative helpers are isolated
# fakes that record calls. No Proxmox command, backup, or package operation runs.
HELPER = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

kind = sys.argv[1]
args = sys.argv[2:]
if kind == "inventory":
    if args != [os.environ["FORGE_TEST_RUNNING_LXC"], os.environ["FORGE_TEST_EXCLUDE"]]:
        sys.exit("unexpected inventory policy")
    vmids = os.environ.get("FORGE_TEST_INVENTORY_VMIDS", os.environ["FORGE_TEST_VMIDS"])
    excluded = {x.strip() for x in args[1].split(",") if x.strip()}
    stopped = set(filter(None, os.environ.get("FORGE_TEST_STOPPED_VMIDS", "").split(",")))
    templates = set(filter(None, os.environ.get("FORGE_TEST_TEMPLATE_VMIDS", "").split(",")))
    for vmid in sorted(filter(None, vmids.split(",")), key=int):
        name = f"guest{vmid}"
        if vmid in templates:
            policy = "template"
        elif vmid in stopped:
            policy = "stopped"
        elif vmid in excluded or name in excluded:
            policy = "excluded"
        elif args[0] == "false":
            policy = "running_lxc_disabled"
        else:
            policy = "eligible"
        state = "stopped" if vmid in stopped else "running"
        print(f"{vmid}\t{name}\t{state}\t{policy}")
    sys.exit(0)

with Path(os.environ["FORGE_TEST_CALLS"]).open("a") as log:
    log.write(json.dumps({"kind": kind, "args": args,
                          "fallback": os.environ.get("FORGE_LXC_BACKUP_ONLY_VMIDS", "")}) + "\n")

if kind == "list":
    if args != [os.environ["FORGE_TEST_RUNNING_LXC"], os.environ["FORGE_TEST_EXCLUDE"]]:
        sys.exit("unexpected selection policy")
    if args[0] == "true":
        if os.environ.get("FORGE_TEST_MALFORMED_TARGET") == "true":
            print("type=lxc name=missing_id state=running template=false")
        else:
            exclusions = {value.strip() for value in args[1].split(",") if value.strip()}
            for vmid in filter(None, os.environ["FORGE_TEST_VMIDS"].split(",")):
                if vmid in exclusions or f"guest{vmid}" in exclusions:
                    continue
                print(f"type=lxc vmid={vmid} name=guest{vmid} state=running template=false")
elif kind == "space":
    if len(args) != 2 or args[1] != "1024":
        sys.exit("unexpected space threshold")
    if args[0] == os.environ.get("FORGE_TEST_LOW_SPACE_VMID", "FORGE_TEST_LOW_MEMORY_VMID"):
        print("ERROR: insufficient root space", file=sys.stderr)
        sys.exit(1)
elif kind == "memory":
    if len(args) != 2 or args[1] != "128":
        sys.exit("unexpected memory threshold")
    if args[0] == os.environ.get("FORGE_TEST_LOW_MEMORY_VMID"):
        print("ERROR: insufficient available memory", file=sys.stderr)
        sys.exit(1)
elif kind == "preflight":
    if os.environ.get("FORGE_TEST_CONFLICT") == "true":
        print("CONFLICT: LXC 111: unsafe restore", file=sys.stderr)
        sys.exit(1)
    for vmid in filter(None, os.environ.get("FORGE_TEST_FALLBACK", "").split(",")):
        if vmid in args:
            print(f"backup_fallback={vmid}")
elif kind == "host":
    code = int(os.environ.get("FORGE_TEST_HOST_CODE", "0"))
    print(f"update={'success' if code == 0 else 'failed'} type=host")
    sys.exit(code)
elif kind == "lxc":
    if len(args) != 2 or args[1] != "scope":
        sys.exit("unexpected LXC invocation")
    code = int(json.loads(os.environ.get("FORGE_TEST_LXC_CODES", "{}")).get(args[0], 0))
    print(f"update={'success' if code == 0 else 'failed'} vmid={args[0]}")
    sys.exit(code)
else:
    sys.exit(f"unexpected helper kind: {kind}")
"""


class ResultAggregationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-aggregation-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        lib = self.root / "lib"
        paths = {
            "workflows/update-all.sh": None,
            "config/get.sh": "config",
            "host/update.sh": "host",
            "lxc/list-targets.sh": "list",
            "config/conflicts.sh": "preflight",
            "preflight/root-space.sh": "space",
            "preflight/memory.sh": "memory",
            "lxc/update.sh": "lxc",
            "results/inventory.sh": "inventory",
            "results/record.sh": None,
        }
        for path, kind in paths.items():
            dest = lib / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            if kind is None:
                dest.symlink_to(ROOT / "lib" / path)
            elif kind == "config":
                dest.write_text(
                    'config_get() {\n'
                    '  declare -gA CONFIG=(\n'
                    '    [UPDATE_HOST]="$FORGE_TEST_UPDATE_HOST"\n'
                    '    [UPDATE_RUNNING_LXC]="$FORGE_TEST_RUNNING_LXC"\n'
                    '    [EXCLUDE]="$FORGE_TEST_EXCLUDE"\n'
                    '    [MIN_ROOT_FREE_MB]=1024\n'
                    '    [MIN_MEM_AVAILABLE_MB]=128\n'
                    '  )\n'
                    '}\n', encoding="utf-8",
                )
            else:
                dest.write_text(
                    '#!/bin/bash\n'
                    'exec python3 "$FORGE_TEST_HELPER" "' + kind + '" "$@"\n',
                    encoding="utf-8",
                )
        helper = self.root / "helper.py"
        helper.write_text(HELPER, encoding="utf-8")
        guard = self.root / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        self.calls_file = self.root / "calls.jsonl"
        self.env = os.environ.copy()
        self.env.update({
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_HELPER": str(helper),
            "FORGE_TEST_CALLS": str(self.calls_file),
            "FORGE_TEST_UPDATE_HOST": "true",
            "FORGE_TEST_RUNNING_LXC": "true",
            "FORGE_TEST_EXCLUDE": "",
            "FORGE_TEST_VMIDS": "100,111,115",
        })
        for key in ("FORGE_TEST_HOST_CODE", "FORGE_TEST_LXC_CODES",
                    "FORGE_TEST_CONFLICT", "FORGE_TEST_FALLBACK",
                    "FORGE_TEST_MALFORMED_TARGET", "FORGE_TEST_LOW_SPACE_VMID"):
            self.env.pop(key, None)

    def invoke(self, mode="lxc", **overrides):
        self.calls_file.unlink(missing_ok=True)
        env = {**self.env, **{key: str(value) for key, value in overrides.items()}}
        result = subprocess.run(
            ["bash", str(self.root / "lib/workflows/update-all.sh"), mode],
            cwd=self.root, env=env, capture_output=True, text=True, check=False,
        )
        calls = ([json.loads(line) for line in self.calls_file.read_text().splitlines()]
                 if self.calls_file.exists() else [])
        return result, calls

    def assert_calls(self, calls, expected):
        self.assertEqual(
            [(call["kind"], call["args"]) for call in calls], expected
        )

    def test_all_lxcs_succeed(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_calls(calls, [
            ("list", ["true", ""]),
            ("space", ["100", "1024"]),
            ("space", ["111", "1024"]),
            ("space", ["115", "1024"]),
            ("memory", ["100", "128"]),
            ("memory", ["111", "128"]),
            ("memory", ["115", "128"]),
            ("preflight", ["100", "111", "115"]),
            ("lxc", ["100", "scope"]),
            ("lxc", ["111", "scope"]),
            ("lxc", ["115", "scope"]),
        ])
        self.assertIn("update_all_stage=success stage=lxc total=3 succeeded=3 failed=0", result.stdout)
        self.assertIn("update_all=success mode=lxc", result.stdout)
        self.assertIn("Forge update summary: 3 LXCs selected, 3 succeeded, 0 failed; overall SUCCESS.", result.stdout)

    def test_one_guest_failure_keeps_later_guests_running(self):
        result, calls = self.invoke(
            FORGE_TEST_LXC_CODES=json.dumps({"111": 42})
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111", "115"])
        self.assertIn("update_all_target=failed vmid=111 exit_code=42", result.stdout)
        self.assertIn("update_all=failed stage=lxc total=3 succeeded=2 failed=1 exit_code=1",
                      result.stdout)
        self.assertNotIn("update_all=success", result.stdout)
        self.assertIn("Forge update summary: 3 LXCs selected, 2 succeeded, 1 failed; overall FAILED.", result.stdout)
        self.assertIn("Failed LXC: 111 (exit code 42)", result.stdout)

    def test_multiple_guest_failures_are_all_counted(self):
        result, calls = self.invoke(
            FORGE_TEST_LXC_CODES=json.dumps({"100": 3, "115": 42})
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len([c for c in calls if c["kind"] == "lxc"]), 3)
        self.assertIn("update_all=failed stage=lxc total=3 succeeded=1 failed=2 exit_code=1",
                      result.stdout)

    def test_all_guests_failed(self):
        result, calls = self.invoke(
            FORGE_TEST_LXC_CODES=json.dumps({"100": 2, "111": 5, "115": 7})
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len([c for c in calls if c["kind"] == "lxc"]), 3)
        self.assertIn("update_all=failed stage=lxc total=3 succeeded=0 failed=3 exit_code=1",
                      result.stdout)

    def test_host_failure_preserves_code_and_stops_guest_updates(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_HOST_CODE="42"
        )
        self.assertEqual(result.returncode, 42)
        self.assert_calls(calls, [
            ("list", ["true", ""]),
            ("space", ["100", "1024"]),
            ("space", ["111", "1024"]),
            ("space", ["115", "1024"]),
            ("memory", ["100", "128"]),
            ("memory", ["111", "128"]),
            ("memory", ["115", "128"]),
            ("preflight", ["100", "111", "115"]),
            ("host", []),
        ])
        self.assertIn("update_all=failed stage=host exit_code=42 lxc_started=false",
                      result.stdout)
        self.assertIn("Forge update summary: host FAILED (exit code 42); LXC updates not started (3 selected).", result.stdout)

    def test_successful_host_then_partial_lxc_failure(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_LXC_CODES=json.dumps({"111": 17})
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual([c["kind"] for c in calls],
                         ["list", "space", "space", "space", "memory", "memory", "memory", "preflight", "host", "lxc", "lxc", "lxc"])
        self.assertIn("update_all_stage=success stage=host exit_code=0", result.stdout)
        self.assertIn("update_all=failed stage=lxc total=3 succeeded=2 failed=1 exit_code=1",
                      result.stdout)

    def test_preflight_failure_blocks_every_mutating_target(self):
        result, calls = self.invoke("all", FORGE_TEST_CONFLICT="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c["kind"] for c in calls], ["list", "space", "space", "space", "memory", "memory", "memory", "preflight"])
        self.assertIn("CONFLICT: LXC 111:", result.stderr)

    def test_low_space_blocks_host_and_all_guests(self):
        result, calls = self.invoke("all", FORGE_TEST_LOW_SPACE_VMID="111")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c["kind"] for c in calls], ["list", "space", "space"])
        self.assertIn("space preflight failed", result.stderr)

    def test_low_memory_blocks_host_and_all_guests(self):
        result, calls = self.invoke("all", FORGE_TEST_LOW_MEMORY_VMID="111")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c["kind"] for c in calls],
                         ["list", "space", "space", "space", "memory", "memory"])
        self.assertIn("memory preflight failed", result.stderr)

    def test_no_running_guests_still_reports_success(self):
        result, calls = self.invoke(FORGE_TEST_VMIDS="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_calls(calls, [("list", ["true", ""]), ("preflight", [])])
        self.assertIn("update_all=success mode=lxc", result.stdout)
        self.assertIn("total=0 succeeded=0 failed=0", result.stdout)

    def test_disabled_running_lxc_scope_does_not_run_guests(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_RUNNING_LXC="false"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_calls(calls, [
            ("list", ["false", ""]), ("preflight", []), ("host", [])
        ])
        self.assertIn("update_all_stage=skipped stage=lxc reason=running_lxc_disabled",
                      result.stdout)
        self.assertIn("Forge update summary: host SUCCESS; LXC updates skipped (disabled); overall SUCCESS.", result.stdout)

    def test_disabled_host_while_running_guests_enabled(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_UPDATE_HOST="false"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["kind"] for c in calls],
                         ["list", "space", "space", "space", "memory", "memory", "memory", "preflight", "lxc", "lxc", "lxc"])
        self.assertIn("update_all_stage=skipped stage=host reason=disabled",
                      result.stdout)

    def test_lxc_mode_never_updates_host(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("host", [c["kind"] for c in calls])
        self.assertIn("update_all=start mode=lxc update_host=false", result.stdout)

    def test_fallback_plan_applies_only_to_selected_guest(self):
        result, calls = self.invoke(FORGE_TEST_FALLBACK="111")
        self.assertEqual(result.returncode, 0, result.stderr)
        updates = [c for c in calls if c["kind"] == "lxc"]
        self.assertEqual(len(updates), 3)
        self.assertTrue(all(c["fallback"].strip() == "111" for c in updates))
        self.assertIn("INFO: LXC 111 will use the existing vzdump backup for recovery",
                      result.stdout)

    def test_excluded_vmids_never_reach_mutating_stages(self):
        result, calls = self.invoke("all", FORGE_TEST_EXCLUDE="111,115")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([(c["kind"], c["args"]) for c in calls], [
            ("list", ["true", "111,115"]),
            ("space", ["100", "1024"]),
            ("memory", ["100", "128"]),
            ("preflight", ["100"]),
            ("host", []),
            ("lxc", ["100", "scope"]),
        ])
        self.assertIn("lxc_targets=1", result.stdout)
        self.assertIn("result_target type=lxc vmid=111 name=guest111 selected=false attempted=false status=SKIPPED reason=excluded", result.stdout)

    def test_excluded_hostname_never_reaches_preflight_or_update(self):
        result, calls = self.invoke(FORGE_TEST_EXCLUDE="guest111")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["args"][0] for c in calls if c["kind"] in ("space", "memory", "lxc")],
                         ["100", "115", "100", "115", "100", "115"])
        self.assertEqual(next(c["args"] for c in calls if c["kind"] == "preflight"),
                         ["100", "115"])

    def test_all_excluded_preserves_host_update_and_avoids_guest_mutations(self):
        result, calls = self.invoke("all", FORGE_TEST_EXCLUDE="100,guest111,115")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["kind"] for c in calls], ["list", "preflight", "host"])
        self.assertIn("lxc_targets=0", result.stdout)

    def test_exclusion_has_no_effect_when_scope_disabled(self):
        result, calls = self.invoke("all", FORGE_TEST_RUNNING_LXC="false",
                                    FORGE_TEST_EXCLUDE="111")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["kind"] for c in calls], ["list", "preflight", "host"])

    def test_invalid_target_blocks_host_update(self):
        result, calls = self.invoke("all", FORGE_TEST_MALFORMED_TARGET="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([c["kind"] for c in calls], ["list"])
        self.assertIn("target record returned no vmid", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
