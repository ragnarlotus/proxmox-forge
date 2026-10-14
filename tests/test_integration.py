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
    "snapshots": {
        "100": [{"name": "current"}],
        "111": [{"name": "current"}],
        "113": [{"name": "Update_20260614_073449"}, {"name": "current"}],
    },
    "configs": {
        "100": "rootfs: local-lvm:vm-100-disk-0,size=12G\n",
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

    def test_all_selected_guests_use_backup_only_independent_of_snapshot_support(self):
        result, calls = self.invoke(["100", "111"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn(["pct", "config", "100"], calls)
        self.assertIn(["pct", "config", "111"], calls)
        self.assertFalse(any("feature" in str(c) for c in calls))

    def test_existing_snapshots_block_automatic_restore_without_deletion(self):
        result, calls = self.invoke(["113"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("would destroy existing persistent snapshots", result.stderr)
        self.assertIn("review/remove them manually", result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(["pct", "config", "113"], calls)

    def test_conflicts_block_partial_scope(self):
        result, _ = self.invoke(["111", "113"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONFLICT: LXC 113:", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_backup_disabled_rejected_even_if_rollback_disabled(self):
        for disabled in (
            "CREATE_BACKUP_BEFORE_LXC_UPDATE=false\n",
            "CREATE_BACKUP_BEFORE_LXC_UPDATE=false\nROLLBACK_ON_FAILURE=false\n",
        ):
            with self.subTest(disabled=disabled):
                result, _ = self.invoke(["100"], override=disabled)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("require CREATE_BACKUP_BEFORE_LXC_UPDATE=true", result.stderr)

    def test_backup_policy_missing_or_ambiguous(self):
        for jobs, expected in (
            ([], "found 0"),
            ([BASE["jobs"][0], BASE["jobs"][0]], "found 2"),
        ):
            with self.subTest(expected=expected):
                result, _ = self.invoke(["111"], changes={"jobs": jobs})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_retention_is_owned_by_proxmox_not_forge_snapshots(self):
        jobs = [{**BASE["jobs"][0], "prune-backups": "keep-daily=7"}]
        result, _ = self.invoke(["111"], changes={"jobs": jobs})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_snapshot_listing_failure_blocks_safe_recovery(self):
        result, _ = self.invoke(["111"], changes={"snapshots": {}})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CONFLICT: LXC 111:", result.stderr)

    def test_rootfs_must_be_storage_backed(self):
        result, _ = self.invoke(
            ["111"], changes={"configs": {"111": "rootfs: /srv/share\n"}}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("storage-backed rootfs", result.stderr)

    def test_backup_only_updates_can_disable_automatic_restore(self):
        result, calls = self.invoke(
            ["113"], override="ROLLBACK_ON_FAILURE=false\n"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] == "pct" for c in calls))
        self.assertFalse(any("snapshot" in str(c) for c in calls))

    def test_snapshot_feature_probe_is_never_called(self):
        result, calls = self.invoke(["100", "111"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("feature" in str(c) for c in calls))

    def test_invalid_snapshot_metadata_blocks_auto_restore(self):
        result, _ = self.invoke(
            ["100"], changes={"snapshots": {"100": [{"name": "current"}, {"invalid": True}]}}
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("persistent snapshots", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
