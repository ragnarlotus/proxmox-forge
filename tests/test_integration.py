#!/usr/bin/env python3
"""F213: run Forge's actual LXC recovery preflight against fake Proxmox tools."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# Mock only the external Proxmox commands. Unexpected or mutating commands
# fail the test; the Forge configuration and conflict-checker code remain real.
MOCK_TOOL = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
fixture = json.loads(Path(os.environ["FORGE_TEST_FIXTURE"]).read_text())
with Path(os.environ["FORGE_TEST_CALLS"]).open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")

if name == "hostname" and args == ["-s"]:
    print("bv")
elif name == "pvesh" and args == [
    "get", "/cluster/backup", "--output-format", "json"
]:
    print(json.dumps(fixture["jobs"]))
elif name == "pvesh" and len(args) == 6 and args[0] == "get" and (
    args[2:] == ["--feature", "snapshot", "--output-format", "json"]
):
    parts = args[1].split("/")
    if len(parts) == 6 and parts[1:4] == ["nodes", "bv", "lxc"] and parts[-1] == "feature":
        vmid = parts[4]
        if vmid in fixture["features"]:
            print(json.dumps({"hasFeature": fixture["features"][vmid]}))
            sys.exit(0)
    sys.exit(91)
elif name == "pvesh" and len(args) == 4 and args[0] == "get" and (
    args[2:] == ["--output-format", "json"]
):
    parts = args[1].split("/")
    if len(parts) == 6 and parts[1:4] == ["nodes", "bv", "lxc"] and parts[-1] == "snapshot":
        vmid = parts[4]
        if vmid in fixture["snapshots"]:
            print(json.dumps(fixture["snapshots"][vmid]))
            sys.exit(0)
    sys.exit(92)
elif name == "pct" and len(args) == 2 and args[0] == "config":
    vmid = args[1]
    if vmid in fixture["configs"]:
        print(fixture["configs"][vmid], end="")
    else:
        sys.exit(93)
else:
    print(f"unexpected external command: {name} {args}", file=sys.stderr)
    sys.exit(94)
"""

# Create Forge's runtime state using the REAL production configuration loader;
# only the parent process and Proxmox runtime guard are simulated.
PREFLIGHT = r"""
source "$1/lib/config/get.sh" || exit 1
config_get_files "$1/forge.conf.default" "$2" || exit 1
{
  printf 'meta\trun_id\tmock-run\n'
  for key in "${!CONFIG[@]}"; do
    printf 'config\t%s\t%s\n' "$key" "${CONFIG[$key]}"
  done
} > "$FORGE_LOCK_FILE" || exit 1
export FORGE_RUNTIME_CONFIG_READY=true
bash "$1/lib/config/conflicts.sh" "${@:3}"
"""

BASE = {
    "jobs": [{
        "enabled": 1,
        "node": "bv",
        "all": 1,
        "storage": "backups",
        "prune-backups": "keep-last=3",
    }],
    "features": {"100": 1, "111": 0, "113": 0},
    "snapshots": {
        "111": [{"name": "current"}],
        "113": [{"name": "Update_20260614_073449"}, {"name": "current"}],
    },
    "configs": {
        "111": "rootfs: local-lvm:vm-111-disk-0,size=20G\n"
               "mp0: /mnt/nvme500/snowshare-uploads,mp=/opt/snowshare_data,backup=0\n",
        "113": "rootfs: local-lvm:vm-113-disk-0,size=28G\n",
    },
}


class RecoveryPreflightTests(unittest.TestCase):
    def invoke(self, vmids, override=None, changes=None):
        with tempfile.TemporaryDirectory(prefix="forge-integration-") as tmp:
            directory = Path(tmp)
            fake_bin = directory / "bin"
            fake_bin.mkdir()
            fake_tool = fake_bin / "mock-tool"
            fake_tool.write_text(MOCK_TOOL, encoding="utf-8")
            fake_tool.chmod(0o755)
            for name in ("pvesh", "pct", "hostname"):
                (fake_bin / name).symlink_to(fake_tool)

            fixture = json.loads(json.dumps(BASE))
            if changes:
                fixture.update(changes)
            fixture_path = directory / "fixture.json"
            fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
            calls_path = directory / "calls.jsonl"
            guard = directory / "guard.sh"
            guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
            override_path = directory / "forge.conf"
            if override is not None:
                override_path.write_text(override, encoding="utf-8")

            env = os.environ.copy()
            env.update({
                "PATH": f"{fake_bin}:{env['PATH']}",
                "FORGE_TEST_FIXTURE": str(fixture_path),
                "FORGE_TEST_CALLS": str(calls_path),
                "FORGE_RUNTIME_GUARD": str(guard),
                "FORGE_RUN_ID": "mock-run",
                "FORGE_LOCK_FILE": str(directory / "run-state"),
            })
            env.pop("FORGE_RUNTIME_CONFIG_READY", None)

            result = subprocess.run(
                ["bash", "-c", PREFLIGHT, "test-preflight",
                 str(ROOT), str(override_path), *vmids],
                text=True, capture_output=True, check=False, cwd=ROOT, env=env,
            )
            calls = (
                [json.loads(line) for line in calls_path.read_text().splitlines()]
                if calls_path.exists() else []
            )
            self.assertTrue(
                all(call[0] in ("pvesh", "pct", "hostname") for call in calls),
                calls,
            )
            self.assertTrue(
                all(call[0] != "pct" or call[1] == "config" for call in calls),
                calls,
            )
            return result, calls

    def test_snapshot_capable_guest_needs_no_backup_fallback(self):
        result, calls = self.invoke(["100"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertFalse(any(c[0] == "pct" for c in calls))

    def test_snapshot_incompatible_guest_uses_backup_by_default(self):
        result, calls = self.invoke(["100", "111"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "backup_fallback=111")
        self.assertIn(["pct", "config", "111"], calls)

    def test_existing_snapshots_block_restore(self):
        result, calls = self.invoke(["113"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backup restore would destroy existing persistent snapshots",
                      result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(["pct", "config", "113"], calls)

    def test_all_conflicts_block_partial_recovery_plan(self):
        result, _ = self.invoke(["111", "113"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONFLICT: LXC 113:", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_explicit_opt_out_rejects_unsupported_snapshots(self):
        result, calls = self.invoke(
            ["111"], override="BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=false\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=false", result.stderr)
        self.assertFalse(any(c[0] == "pct" for c in calls))

    def test_backup_disabled_rejects_fallback(self):
        result, _ = self.invoke(
            ["111"], override="CREATE_BACKUP_BEFORE_LXC_UPDATE=false\n"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires CREATE_BACKUP_BEFORE_LXC_UPDATE=true", result.stderr)

    def test_backup_policy_missing_or_ambiguous(self):
        for jobs, expected in (
            ([], "found 0"),
            ([BASE["jobs"][0], BASE["jobs"][0]], "found 2"),
        ):
            with self.subTest(expected=expected):
                result, _ = self.invoke(["111"], changes={"jobs": jobs})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_invalid_backup_retention_rejected(self):
        jobs = [{**BASE["jobs"][0], "prune-backups": "keep-last=0"}]
        result, _ = self.invoke(["111"], changes={"jobs": jobs})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("keep-last greater than zero", result.stderr)

    def test_snapshot_api_failure_blocks_fallback(self):
        result, _ = self.invoke(
            ["111"], changes={"snapshots": {}}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONFLICT: LXC 111:", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_rootfs_must_be_storage_backed(self):
        result, _ = self.invoke(
            ["111"], changes={"configs": {"111": "rootfs: /srv/share\n"}}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("storage-backed rootfs", result.stderr)

    def test_unavailable_feature_response_blocks_update(self):
        result, _ = self.invoke(
            ["111"], changes={"features": {"111": 2}}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid snapshot feature response", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
