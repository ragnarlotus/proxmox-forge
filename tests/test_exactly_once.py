#!/usr/bin/env python3
"""F207: verify single execution of mutating stages by the real LXC orchestrator."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

# The real update.sh is symlinked into an isolated layout. All of its normal
# relative helper paths point to test doubles; no host or guest can be changed.
HELPER = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

name = sys.argv[1]
args = sys.argv[2:]
calls = Path(os.environ["FORGE_TEST_CALLS"])

def record(component, arguments=None):
    with calls.open("a") as handle:
        handle.write(json.dumps({"component": component, "args": arguments or []}) + "\n")

if name == "get-target.sh":
    print("type=lxc vmid=111 name=share state=running template=false")
elif name == "get-state.sh":
    print("running")
elif name == "init.sh":
    path = Path(os.environ["FORGE_TEST_LOG"])
    path.touch()
    print(path)
elif name == "write.sh":
    pass
elif name == "capture.sh":
    if len(args) < 4 or args[2] != "--" or args[3] != "bash":
        sys.exit("invalid simulated capture command")
    record("capture", [args[1]])
    sys.exit(subprocess.run(args[3:], check=False).returncode)
elif name == "check-requirements.sh":
    record("requirements")
    print("requirements=ok vmid=111 name=share state=running "
          "template=false package_manager=apt application_updater=/usr/bin/update")
else:
    components = {
        "create.sh": "backup",
        "snapshot.sh": "snapshot",
        "os.sh": "os",
        "application.sh": "application",
        "custom-scripts.sh": "custom",
        "health.sh": "health",
        "fstrim.sh": "fstrim",
        "reboot-required.sh": "reboot",
        "held-packages.sh": "held",
        "recover.sh": "recover",
    }
    if name not in components:
        print(f"unexpected helper: {name}", file=sys.stderr)
        sys.exit(99)

    component = components[name]
    record(component, args)
    if component == os.environ.get("FORGE_TEST_FAIL_STAGE") or (
        component == "recover" and os.environ.get("FORGE_TEST_FAIL_RECOVERY") == "true"
    ):
        sys.exit(int(os.environ.get("FORGE_TEST_FAIL_CODE", "42")))

    if component == "backup":
        print("backup=success vmid=111 storage=backups "
              "volume=backups:backup/vzdump-lxc-111-test.tar.zst")
    elif component == "snapshot":
        print("snapshot=success vmid=111 name=Update_test")
    elif component == "reboot":
        print("reboot_required=yes type=lxc vmid=111 marker=yes")
    elif component == "held":
        print("held_packages=0 type=lxc vmid=111")
"""


class ExactlyOnceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-once-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        lib = self.root / "lib"

        paths = [
            "lxc/update.sh", "config/get.sh", "lxc/get-target.sh",
            "lxc/get-state.sh", "workflows/check-requirements.sh",
            "backup/lxc/create.sh", "backup/lxc/snapshot.sh",
            "lxc/recover.sh", "postflight/reboot-required.sh", "preflight/held-packages.sh", "lxc/update/os.sh",
            "lxc/update/application.sh", "lxc/update/custom-scripts.sh",
            "lxc/update/fstrim.sh", "lxc/health.sh",
            "logging/init.sh", "logging/capture.sh", "logging/write.sh",
        ]
        for path in paths:
            target = lib / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if path == "lxc/update.sh":
                target.symlink_to(ROOT / "lib/lxc/update.sh")
            elif path == "config/get.sh":
                target.write_text(
                    'config_get() {\n'
                    '  declare -gA CONFIG=(\n'
                    '    [LOG_DIR]="$FORGE_TEST_LOG_DIR"\n'
                    '    [LOG_KEEP]=8\n'
                    '    [CUSTOM_SCRIPTS_DIR]="$FORGE_TEST_SCRIPTS"\n'
                    '    [RUN_CUSTOM_SCRIPTS]="$FORGE_TEST_CUSTOM_SCRIPTS"\n'
                    '    [UPDATE_LXC_OS]="$FORGE_TEST_OS"\n'
                    '    [UPDATE_LXC_APPLICATION]="$FORGE_TEST_APPLICATION"\n'
                    '    [CREATE_BACKUP_BEFORE_LXC_UPDATE]=true\n'
                    '    [ROLLBACK_ON_FAILURE]=true\n'
                    '    [HEALTH_CHECK]=true\n'
                    '  )\n'
                    '}\n', encoding="utf-8",
                )
            else:
                target.write_text(
                    '#!/bin/bash\n'
                    'exec python3 "$FORGE_TEST_HELPER" "$(basename "$0")" "$@"\n',
                    encoding="utf-8",
                )

        self.helper = self.root / "helper.py"
        self.helper.write_text(HELPER, encoding="utf-8")
        guard = self.root / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        script_dir = self.root / "custom" / "111"
        script_dir.mkdir(parents=True)
        (script_dir / "01-example.sh").write_text(
            "#!/bin/bash\nexit 0\n", encoding="utf-8"
        )
        self.calls_path = self.root / "calls.jsonl"
        self.env = os.environ.copy()
        self.env.update({
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_LXC_BACKUP_ONLY_VMIDS": "",
            "FORGE_TEST_HELPER": str(self.helper),
            "FORGE_TEST_CALLS": str(self.calls_path),
            "FORGE_TEST_LOG": str(self.root / "update.log"),
            "FORGE_TEST_LOG_DIR": str(self.root),
            "FORGE_TEST_SCRIPTS": str(self.root / "custom"),
            "FORGE_TEST_OS": "true",
            "FORGE_TEST_APPLICATION": "true",
            "FORGE_TEST_CUSTOM_SCRIPTS": "true",
        })

    def invoke(self, **overrides):
        env = {**self.env, **{key: str(value) for key, value in overrides.items()}}
        result = subprocess.run(
            ["bash", str(self.root / "lib/lxc/update.sh"), "111"],
            cwd=self.root, env=env, capture_output=True, text=True, check=False,
        )
        calls = [
            json.loads(line)
            for line in self.calls_path.read_text().splitlines()
        ] if self.calls_path.exists() else []
        steps = [c["component"] for c in calls
                 if c["component"] not in ("capture", "requirements")]
        return result, steps, calls

    def test_success_runs_each_mutating_stage_exactly_once(self):
        result, steps, _ = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            steps, ["held", "backup", "snapshot", "os", "application",
                    "custom", "health", "fstrim", "reboot"],
        )
        self.assertIn("update=success", result.stdout)
        self.assertIn("reboot_required=yes", result.stdout)
        self.assertEqual(steps.count("reboot"), 1)
        self.assertIn("Forge update summary: LXC 111 SUCCESS (final state: running).", result.stdout)

    def test_failure_stops_later_stages_and_recovers_only_once(self):
        stages = ["backup", "snapshot", "os", "application", "custom", "health"]
        for stage in stages:
            with self.subTest(stage=stage):
                self.calls_path.unlink(missing_ok=True)
                result, steps, calls = self.invoke(FORGE_TEST_FAIL_STAGE=stage)
                self.assertEqual(result.returncode, 42, result.stderr)
                expected = ["held"] + stages[:stages.index(stage) + 1]
                if stage in ("os", "application", "custom", "health"):
                    expected.append("recover")
                    recover = [c for c in calls if c["component"] == "recover"]
                    self.assertEqual(len(recover), 1)
                    self.assertEqual(recover[0]["args"][5], "snapshot")
                    self.assertEqual(recover[0]["args"][-1], "42")
                self.assertEqual(steps, expected)
                self.assertNotIn("reboot", steps)
                self.assertIn("update=failed", result.stdout)
                reported_stage = {"os": "os_update", "application": "application_update",
                                  "custom": "custom_scripts"}.get(stage, stage)
                self.assertIn(
                    f"Forge update summary: LXC 111 FAILED at {reported_stage} (exit code 42).",
                    result.stdout,
                )

    def test_fallback_uses_one_backup_no_snapshot_and_one_restore_attempt(self):
        result, steps, calls = self.invoke(
            FORGE_LXC_BACKUP_ONLY_VMIDS=" 111",
            FORGE_TEST_FAIL_STAGE="custom",
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(
            steps, ["held", "backup", "os", "application", "custom", "recover"]
        )
        recover = [c for c in calls if c["component"] == "recover"]
        self.assertEqual(len(recover), 1)
        self.assertEqual(recover[0]["args"][5], "backup")
        self.assertEqual(recover[0]["args"][1],
                         "backups:backup/vzdump-lxc-111-test.tar.zst")
        self.assertEqual(recover[0]["args"][-1], "42")

    def test_failed_recovery_does_not_repeat_primary_mutation(self):
        result, steps, _ = self.invoke(
            FORGE_TEST_FAIL_STAGE="os", FORGE_TEST_FAIL_RECOVERY="true",
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(steps, ["held", "backup", "snapshot", "os", "recover"])

    def test_nonfatal_fstrim_failure_is_not_retried(self):
        result, steps, _ = self.invoke(FORGE_TEST_FAIL_STAGE="fstrim")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            steps, ["held", "backup", "snapshot", "os", "application",
                    "custom", "health", "fstrim", "reboot"],
        )
        self.assertIn("WARNING: post-update fstrim failed", result.stderr)

    def test_held_packages_failure_is_nonfatal_and_not_retried(self):
        result, steps, _ = self.invoke(FORGE_TEST_FAIL_STAGE="held")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(steps.count("held"), 1)
        self.assertEqual(steps.count("os"), 1)
        self.assertIn("WARNING: could not inspect held APT packages", result.stderr)

    def test_reboot_detection_failure_is_nonfatal(self):
        result, steps, _ = self.invoke(FORGE_TEST_FAIL_STAGE="reboot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(steps.count("reboot"), 1)
        self.assertIn("reboot_required=unknown", result.stdout)
        self.assertIn("WARNING: could not determine reboot requirement", result.stderr)

    def test_no_mutations_when_all_update_stages_disabled(self):
        result, steps, _ = self.invoke(
            FORGE_TEST_OS="false",
            FORGE_TEST_APPLICATION="false",
            FORGE_TEST_CUSTOM_SCRIPTS="false",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(steps, ["held", "reboot"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
