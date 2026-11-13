#!/usr/bin/env python3
"""Verify exact backup artifact identification with overlapping Proxmox jobs."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = ROOT / "lib/backup/lxc/create.sh"
OLD = "backups:backup/vzdump-lxc-105-2026_11_11-05_08_16.tar.zst"
CONCURRENT = "backups:backup/vzdump-lxc-105-2026_11_13-05_11_26.tar.zst"
OWN = "backups:backup/vzdump-lxc-105-2026_11_13-05_19_20.tar.zst"

# Run the real create.sh, with only its host-specific /etc/pve path redirected
# to a temporary file. All Proxmox binaries are isolated test doubles.
MOCK_TOOL = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
fixture = json.loads(Path(os.environ["TEST_FIXTURE"]).read_text())
root = Path(os.environ["TEST_ROOT"])
marker = root / "backup-executed"

with (root / "calls.jsonl").open("a") as calls:
    calls.write(json.dumps([name, *args]) + "\n")

if name == "hostname" and args == ["-s"]:
    print("bv")
elif name == "pvesh" and args == ["get", "/cluster/backup", "--output-format", "json"]:
    print(json.dumps([{
        "enabled": 1, "node": "bv", "vmid": "105", "storage": "backups",
        "mode": "snapshot", "compress": "zstd", "prune-backups": "keep-last=3",
    }]))
elif name == "vzdump" and args == ["help"]:
    print("\n".join(f"  --{option} value" for option in
                    ("storage", "mode", "compress", "prune-backups")))
elif name == "vzdump" and args and args[0] == "105":
    marker.touch()
    print("INFO: trying to get global lock - waiting...")
    print("INFO: got global lock")
    paths = fixture.get("reported_paths")
    if paths is None:
        paths = [str(root / "dump" / Path(fixture["own"]).name)]
    for path in paths:
        print(f"INFO: creating vzdump archive '{path}'")
    if fixture.get("vzdump_error"):
        print("ERROR: backup failed")
        sys.exit(fixture["vzdump_error"])
    print("INFO: Backup job finished successfully")
elif name == "pvesm" and args == ["list", "backups", "--vmid", "105", "--content", "backup"]:
    print("Volid Format Type Size VMID")
    for volid in fixture["after"] if marker.exists() else fixture["before"]:
        print(f"{volid} tar.zst backup 2048 105")
elif name == "pvesm" and len(args) == 2 and args[0] == "path":
    if args[1] not in fixture["after"]:
        print("unexpected backup volume", file=sys.stderr)
        sys.exit(91)
    print(root / "dump" / Path(args[1]).name)
else:
    print(f"unexpected tool: {name} {args}", file=sys.stderr)
    sys.exit(92)
"""


class BackupIdentityTests(unittest.TestCase):
    def run_case(self, after=None, reported_paths=None, no_path=False,
                 vzdump_error=0):
        with tempfile.TemporaryDirectory(prefix="forge-backup-id-") as tmp:
            root = Path(tmp)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            test_tool = bin_dir / "tool"
            test_tool.write_text(MOCK_TOOL)
            test_tool.chmod(0o755)
            for name in ("hostname", "pvesh", "vzdump", "pvesm"):
                (bin_dir / name).symlink_to(test_tool)

            lxc_dir = root / "lxc"
            lxc_dir.mkdir()
            (lxc_dir / "105.conf").write_text("rootfs: local-lvm:vm-105-disk-0\n")
            guard = root / "guard.sh"
            guard.write_text("#!/bin/bash\nexit 0\n")

            source = ORIGINAL.read_text()
            original_path = '"/etc/pve/lxc/${vmid}.conf"'
            self.assertEqual(source.count(original_path), 1)
            script = root / "create.sh"
            script.write_text(source.replace(
                original_path, '"' + str(lxc_dir) + '/${vmid}.conf"'
            ))
            fixture = {
                "before": [OLD],
                "after": after if after is not None else [OLD, CONCURRENT, OWN],
                "own": OWN,
                "vzdump_error": vzdump_error,
            }
            if no_path:
                fixture["reported_paths"] = []
            elif reported_paths is not None:
                fixture["reported_paths"] = reported_paths
            fixture_file = root / "fixture.json"
            fixture_file.write_text(json.dumps(fixture))
            env = {
                **os.environ,
                "PATH": f"{bin_dir}:{os.environ['PATH']}",
                "TEST_FIXTURE": str(fixture_file),
                "TEST_ROOT": str(root),
                "FORGE_RUNTIME_GUARD": str(guard),
            }
            result = subprocess.run(
                ["bash", str(script), "105"], cwd=root, env=env,
                capture_output=True, text=True, check=False,
            )
            calls_path = root / "calls.jsonl"
            calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
            return result, calls

    def test_concurrent_backup_selects_only_own_archive(self):
        result, calls = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("backup=success vmid=105 storage=backups volume=" + OWN,
                      result.stdout)
        self.assertEqual(
            [args for name, *args in calls if name == "pvesm" and args[0] == "path"],
            [["path", CONCURRENT], ["path", OWN]],
        )

    def test_single_new_backup_is_still_identified(self):
        result, _ = self.run_case(after=[OLD, OWN])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("volume=" + OWN, result.stdout)

    def test_no_path_with_single_new_volume_preserves_old_fallback(self):
        result, _ = self.run_case(after=[OLD, OWN], no_path=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("volume=" + OWN, result.stdout)

    def test_no_path_with_concurrent_volumes_fails_closed(self):
        result, _ = self.run_case(no_path=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("new volumes: 2", result.stderr)
        self.assertNotIn("backup=success", result.stdout)

    def test_mismatched_vzdump_path_fails_closed(self):
        result, _ = self.run_case(reported_paths=["/wrong/archive.tar.zst"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not uniquely match", result.stderr)

    def test_multiple_archive_paths_fail_closed(self):
        result, _ = self.run_case(reported_paths=["/one.tar.zst", "/two.tar.zst"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("multiple created archives", result.stderr)

    def test_vzdump_failure_keeps_authoritative_exit_code(self):
        result, _ = self.run_case(vzdump_error=23)
        self.assertEqual(result.returncode, 23)
        self.assertIn("vzdump backup failed", result.stderr)
        self.assertNotIn("backup=success", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
