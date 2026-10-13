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
        pass
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
            "results/record.sh", "results/table.py", "results/apt.sh", "results/application.sh",
        ]
        for path in paths:
            target = lib / path
            target.parent.mkdir(parents=True, exist_ok=True)
            if path in ("lxc/update.sh", "results/record.sh", "results/table.py"):
                target.symlink_to(ROOT / "lib" / path)
            elif path == "results/application.sh":
                target.write_text(
                    'FORGE_APP_BEFORE="-"; FORGE_APP_AFTER="-"; FORGE_APP_REPOSITORY="-"; FORGE_APP_FINISHED=false\n'
                    'forge_app_begin() {\n'
                    '  FORGE_APP_BEFORE="${FORGE_TEST_APP_BEFORE:-1.0}"\n'
                    '  FORGE_APP_REPOSITORY="${FORGE_TEST_APP_REPOSITORY:-https://github.com/pi-hole/pi-hole}"\n'
                    '}\n'
                    'forge_app_finalize() {\n'
                    '  [[ "$FORGE_APP_FINISHED" == true ]] && return 0\n'
                    '  FORGE_APP_FINISHED=true\n'
                    '  FORGE_APP_AFTER="${FORGE_TEST_APP_AFTER:-2.0}"\n'
                    '  if [[ -n "${FORGE_TEST_FAIL_STAGE:-}" && "${FORGE_TEST_FAIL_RECOVERY:-}" != true && "${FORGE_TEST_FAIL_STAGE}" != fstrim && "${FORGE_TEST_FAIL_STAGE}" != held && "${FORGE_TEST_FAIL_STAGE}" != reboot ]]; then\n'
                    '    FORGE_APP_AFTER="$FORGE_APP_BEFORE"\n'
                    '  fi\n'
                    '  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk && -n "${FORGE_APP_RESULT_FILE:-}" ]]; then\n'
                    '    printf "%s\\t%s\\t%s\\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER" "$FORGE_APP_REPOSITORY" > "$FORGE_APP_RESULT_FILE"\n'
                    '  fi\n'
                    '}\n', encoding="utf-8",
                )
            elif path == "results/apt.sh":
                target.write_text(
                    'FORGE_APT_ACTIVE=false\n'
                    'FORGE_APT_COUNT="-"; FORGE_APT_FINISHED=false\n'
                    'forge_apt_begin() { :; }\n'
                    'forge_apt_cleanup() { :; }\n'
                    'forge_apt_finalize() {\n'
                    '  [[ "$FORGE_APT_FINISHED" == true ]] && return 0\n'
                    '  FORGE_APT_FINISHED=true\n'
                    '  if [[ "$FORGE_APT_ACTIVE" == true ]]; then\n'
                    '    FORGE_APT_COUNT="${FORGE_TEST_APT_COUNT:-2}"\n'
                    '    if [[ -n "${FORGE_TEST_FAIL_STAGE:-}" && "${FORGE_TEST_FAIL_RECOVERY:-}" != true && "${FORGE_TEST_FAIL_STAGE}" != fstrim && "${FORGE_TEST_FAIL_STAGE}" != held && "${FORGE_TEST_FAIL_STAGE}" != reboot ]]; then\n'
                    '      FORGE_APT_COUNT="${FORGE_TEST_ROLLED_BACK_APT_COUNT:-0}"\n'
                    '    fi\n'
                    '  fi\n'
                    '  if [[ "${FORGE_RESULTS_AGGREGATE:-}" == bulk && -n "${FORGE_APT_RESULT_FILE:-}" ]]; then\n'
                    '    printf "%s\\n" "$FORGE_APT_COUNT" > "$FORGE_APT_RESULT_FILE"\n'
                    '  fi\n'
                    '}\n', encoding="utf-8",
                )
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
            steps, ["backup", "snapshot", "os", "held", "application",
                    "custom", "health", "fstrim", "reboot"],
        )
        self.assertIn("update=success", result.stdout)
        self.assertIn("reboot_required=yes", result.stdout)
        self.assertEqual(steps.count("reboot"), 1)
        self.assertIn("Forge update summary: LXC 111 SUCCESS (final state: running).", result.stdout)
        self.assertIn("result_target type=lxc vmid=111 name=share selected=true attempted=true status=OK reason=completed apt_upgraded=2", result.stdout)

    def test_bulk_execution_suppresses_nested_result_record(self):
        result, steps, _ = self.invoke(FORGE_RESULTS_AGGREGATE="bulk")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("result_target ", result.stdout)

    def test_failure_stops_later_stages_and_recovers_only_once(self):
        stages = ["backup", "snapshot", "os", "application", "custom", "health"]
        for stage in stages:
            with self.subTest(stage=stage):
                self.calls_path.unlink(missing_ok=True)
                result, steps, calls = self.invoke(FORGE_TEST_FAIL_STAGE=stage)
                self.assertEqual(result.returncode, 42, result.stderr)
                expected = stages[:stages.index(stage) + 1]
                if stage in ("os", "application", "custom", "health"):
                    expected.insert(expected.index("os") + 1, "held")
                if stage in ("os", "application", "custom", "health"):
                    expected.append("recover")
                    recover = [c for c in calls if c["component"] == "recover"]
                    self.assertEqual(len(recover), 1)
                    self.assertEqual(recover[0]["args"][5], "snapshot")
                    self.assertEqual(recover[0]["args"][-1], "42")
                self.assertEqual(steps, expected)
                self.assertNotIn("reboot", steps)
                self.assertIn("update=failed", result.stdout)
                self.assertIn(
                    "result_target type=lxc vmid=111 name=share selected=true attempted=true status=ERROR reason=update_failed exit_code=42",
                    result.stdout,
                )
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
            steps, ["backup", "os", "held", "application", "custom", "recover"]
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
        self.assertEqual(steps, ["backup", "snapshot", "os", "held", "recover"])

    def test_application_versions_before_and_after_shared_result(self):
        result, _, _ = self.invoke(FORGE_TEST_APP_BEFORE="1.2", FORGE_TEST_APP_AFTER="1.3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("app_before=1.2 app_after=1.3", result.stdout)

    def test_f223_repository_survives_success_and_rollback(self):
        for stage, code in [("", 0), ("application", 42)]:
            with self.subTest(stage=stage):
                result, _, _ = self.invoke(
                    FORGE_TEST_FAIL_STAGE=stage,
                    FORGE_TEST_APP_REPOSITORY="https://github.com/pi-hole/pi-hole",
                )
                self.assertEqual(result.returncode, code, result.stderr)
                self.assertIn(
                    "app_repository=https://github.com/pi-hole/pi-hole",
                    result.stdout,
                )

    def test_f223_unknown_repository_is_separate_from_known_version(self):
        result, _, _ = self.invoke(FORGE_TEST_APP_REPOSITORY="-")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("app_before=1.0 app_after=2.0 app_repository=-", result.stdout)

    def test_f224_primary_failure_has_stage_and_recovery_success(self):
        result, steps, _ = self.invoke(FORGE_TEST_FAIL_STAGE="application")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(steps.count("recover"), 1)
        self.assertIn("failed_stage=application_update", result.stdout)
        self.assertIn("recovery=success", result.stdout)
        self.assertIn(
            "result_detail=ERROR%3A%20application_update%20%28exit%2042%29%3B%20recovery%20succeeded",
            result.stdout,
        )

    def test_f224_failed_recovery_does_not_mask_primary_failure(self):
        result, steps, _ = self.invoke(
            FORGE_TEST_FAIL_STAGE="os", FORGE_TEST_FAIL_RECOVERY="true",
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertEqual(steps.count("recover"), 1)
        self.assertIn("failed_stage=os_update recovery=failed:42", result.stdout)
        self.assertIn("recovery%20failed%20%28exit%2042%29", result.stdout)

    def test_f224_nonfatal_warning_does_not_change_success(self):
        result, steps, _ = self.invoke(FORGE_TEST_FAIL_STAGE="fstrim")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(steps.count("fstrim"), 1)
        self.assertIn("status=OK", result.stdout)
        self.assertIn("WARNING%3A%20fstrim%20failed%20%28exit%2042%29", result.stdout)

    def test_f224_bulk_handoff_preserves_result_without_second_record(self):
        handoff = self.root / "result-handoff"
        result, steps, _ = self.invoke(
            FORGE_RESULTS_AGGREGATE="bulk",
            FORGE_RESULT_DETAIL_FILE=str(handoff),
            FORGE_TEST_FAIL_STAGE="application",
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn("result_target ", result.stdout)
        self.assertEqual(steps.count("recover"), 1)
        parts = handoff.read_text(encoding="utf-8").strip().split("\t")
        self.assertEqual(parts[1:], ["application_update", "success"])
        self.assertIn("ERROR%3A%20application_update", parts[0])

    def test_app_version_after_rollback_matches_before(self):
        result, _, _ = self.invoke(
            FORGE_TEST_FAIL_STAGE="application", FORGE_TEST_APP_BEFORE="1.2",
            FORGE_TEST_APP_AFTER="1.3",
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("app_before=1.2 app_after=1.2", result.stdout)

    def test_application_versions_unknown_if_unidentifiable(self):
        result, _, _ = self.invoke(
            FORGE_TEST_APP_BEFORE="-", FORGE_TEST_APP_AFTER="-"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("app_before=- app_after=-", result.stdout)

    def test_success_without_apt_changes_reports_zero(self):
        result, _, _ = self.invoke(FORGE_TEST_APT_COUNT="0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("apt_upgraded=0", result.stdout)

    def test_failure_after_successful_rollback_has_zero_persisted_upgrades(self):
        result, _, _ = self.invoke(FORGE_TEST_FAIL_STAGE="custom")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("exit_code=42 apt_upgraded=0", result.stdout)

    def test_failed_rollback_preserves_partial_upgrade_count(self):
        result, _, _ = self.invoke(
            FORGE_TEST_FAIL_STAGE="os", FORGE_TEST_FAIL_RECOVERY="true"
        )
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("exit_code=42 apt_upgraded=2", result.stdout)

    def test_nonfatal_fstrim_failure_is_not_retried(self):
        result, steps, _ = self.invoke(FORGE_TEST_FAIL_STAGE="fstrim")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            steps, ["backup", "snapshot", "os", "held", "application",
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

    def test_application_only_checks_held_packages_once(self):
        result, steps, _ = self.invoke(FORGE_TEST_OS="false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(steps.count("held"), 1)
        self.assertLess(steps.index("held"), steps.index("application"))
        self.assertNotIn("os", steps)

    def test_application_only_still_reports_installed_package_changes(self):
        result, steps, _ = self.invoke(FORGE_TEST_OS="false", FORGE_TEST_APT_COUNT="5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("os", steps)
        self.assertIn("apt_upgraded=5", result.stdout)

    def test_no_mutations_when_all_update_stages_disabled(self):
        result, steps, _ = self.invoke(
            FORGE_TEST_OS="false",
            FORGE_TEST_APPLICATION="false",
            FORGE_TEST_CUSTOM_SCRIPTS="false",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(steps, ["reboot"])
        self.assertIn("apt_upgraded=-", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
