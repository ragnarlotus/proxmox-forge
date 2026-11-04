#!/usr/bin/env python3
"""F094: exercise the real host update orchestrator with isolated stage fakes."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

HELPER = r"""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

kind = sys.argv[1]
args = sys.argv[2:]
with Path(os.environ["FORGE_TEST_CALLS"]).open("a") as out:
    out.write(json.dumps({"kind": kind, "args": args}) + "\n")

if kind == "init":
    logfile = Path(os.environ["FORGE_TEST_LOG"])
    logfile.touch()
    print(logfile)
elif kind == "capture":
    if len(args) < 5 or args[2] != "--" or args[3] != "bash":
        sys.exit(90)
    sys.exit(subprocess.run(args[3:], check=False).returncode)
elif kind == "requirements":
    print("requirements=ok type=host")
elif kind == "os":
    Path(os.environ["FORGE_TEST_DPKG_STATE"]).write_text(
        "demo\t" + os.environ.get("FORGE_TEST_AFTER_VERSION", "1.2") + "\tii \n"
    )
    sys.exit(int(os.environ.get("FORGE_TEST_OS_FAIL", "0")))
elif kind == "held":
    if os.environ.get("FORGE_TEST_HELD_FAIL") == "true":
        sys.exit(42)
    print("held_packages=0 type=host")
elif kind == "reboot":
    code = int(os.environ.get("FORGE_TEST_REBOOT_FAIL", "0"))
    if code:
        sys.exit(code)
    status = os.environ.get("FORGE_TEST_REBOOT_STATE", "yes")
    kernel_update = os.environ.get(
        "FORGE_TEST_KERNEL_UPDATE", "yes" if status == "yes" else "no"
    )
    print(f"reboot_required={status} type=host marker=no kernel_update={kernel_update} "
          "running_kernel=7.0.14-14-pve latest_installed_kernel=7.0.14-16-pve")
elif kind == "write":
    pass
else:
    sys.exit(f"unexpected helper {kind}")
"""


class HostRebootFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="forge-host-reboot-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        paths = {
            "host/update.sh": None,
            "config/get.sh": "config",
            "host/check-requirements.sh": "requirements",
            "backup/host/create.sh": "backup",
            "host/update/os.sh": "os",
            "preflight/held-packages.sh": "held",
            "postflight/reboot-required.sh": "reboot",
            "logging/init.sh": "init",
            "logging/capture.sh": "capture",
            "logging/write.sh": "write",
            "results/record.sh": None,
            "results/table.py": None,
            "results/apt.sh": None,
            "results/host-software.sh": None,
        }
        for path, kind in paths.items():
            dest = self.base / "lib" / path
            dest.parent.mkdir(parents=True, exist_ok=True)
            if kind is None:
                dest.symlink_to(ROOT / "lib" / path)
            elif kind == "config":
                dest.write_text(
                    'config_get() { declare -gA CONFIG=(\n'
                    '  [UPDATE_HOST]=true\n'
                    '  [CREATE_BACKUP_BEFORE_HOST_UPDATE]=false\n'
                    '  [HEALTH_CHECK]=true\n'
                    '  [LOG_DIR]="$FORGE_TEST_LOG_DIR"\n'
                    '  [LOG_KEEP]=8\n'
                    '); }\n', encoding="utf-8",
                )
            else:
                dest.write_text(
                    '#!/bin/bash\n'
                    'exec python3 "$FORGE_TEST_HELPER" "' + kind + '" "$@"\n',
                    encoding="utf-8",
                )
        log_path = self.base / "log" / "bv.deulo.com" / "host"
        log_path.mkdir(parents=True)
        (log_path / "error.log").touch()

        tools = self.base / "bin"
        tools.mkdir()
        hostname = tools / "hostname"
        hostname.write_text(
            '#!/bin/bash\n[[ "$1" == -f ]] || exit 90\n'
            'printf "bv.deulo.com\\n"\n', encoding="utf-8",
        )
        hostname.chmod(0o755)
        fake_query = tools / "dpkg-query"
        fake_query.write_text(
            '#!/bin/bash\n'
            '[[ "$1" == -W && "$2" == -f=* ]] || exit 91\n'
            'cat "$FORGE_TEST_DPKG_STATE"\n', encoding="utf-8",
        )
        fake_query.chmod(0o755)
        self.dpkg_state = self.base / "dpkg-state"
        guard = self.base / "guard.sh"
        guard.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
        helper = self.base / "helper.py"
        helper.write_text(HELPER, encoding="utf-8")
        self.calls = self.base / "calls.jsonl"
        self.env = {
            **os.environ,
            "FORGE_RUNTIME_GUARD": str(guard),
            "FORGE_TEST_HELPER": str(helper),
            "FORGE_TEST_CALLS": str(self.calls),
            "FORGE_TEST_LOG": str(log_path / "common.log"),
            "FORGE_TEST_LOG_DIR": str(self.base / "log"),
            "FORGE_TEST_DPKG_STATE": str(self.dpkg_state),
            "PATH": f"{tools}:{os.environ['PATH']}",
        }

    def invoke(self, **extra):
        self.calls.unlink(missing_ok=True)
        self.dpkg_state.write_text("demo\t1.0\tii \n", encoding="utf-8")
        result = subprocess.run(
            ["bash", str(self.base / "lib/host/update.sh")],
            env={**self.env, **extra},
            capture_output=True, text=True, check=False,
        )
        calls = [json.loads(x) for x in self.calls.read_text().splitlines()]
        return result, calls

    def test_host_reboot_needed_without_changing_update_success(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=yes", result.stdout)
        self.assertIn("result_target type=host vmid=HOST name=bv.deulo.com selected=true attempted=true status=OK reason=completed apt_upgraded=1", result.stdout)
        self.assertIn("NOTICE: Proxmox host reboot", result.stdout)
        from urllib.parse import unquote
        record = next(line for line in result.stdout.splitlines()
                      if line.startswith("result_target type=host"))
        detail = next(token.split("=", 1)[1] for token in record.split()
                      if token.startswith("result_detail="))
        self.assertIn(
            "WARNING: reboot the Proxmox host to activate the newer installed kernel",
            unquote(detail),
        )
        self.assertIn("Overall result: SUCCESS", result.stdout)
        self.assertEqual([c["kind"] for c in calls].count("reboot"), 1)
        self.assertEqual([c["kind"] for c in calls].count("held"), 1)
        self.assertGreater([c["kind"] for c in calls].index("held"), [c["kind"] for c in calls].index("os"))
        self.assertEqual([c["kind"] for c in calls].count("os"), 1)

    def test_bulk_execution_suppresses_nested_host_record(self):
        from urllib.parse import unquote
        handoff = self.base / "host-result-detail"
        result, calls = self.invoke(
            FORGE_RESULTS_AGGREGATE="bulk",
            FORGE_RESULT_DETAIL_FILE=str(handoff),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("result_target ", result.stdout)
        detail, stage, recovery, platform = handoff.read_text().strip().split("\t")
        self.assertIn("reboot the Proxmox host to activate the newer installed kernel",
                      unquote(detail))
        self.assertEqual(stage, "-")
        self.assertEqual(recovery, "-")

    def test_unchanged_packages_report_zero(self):
        result, _ = self.invoke(FORGE_TEST_AFTER_VERSION="1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("apt_upgraded=0", result.stdout)

    def test_host_without_reboot_signal(self):
        result, calls = self.invoke(FORGE_TEST_REBOOT_STATE="no")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=no", result.stdout)
        self.assertNotIn("NOTICE: Proxmox host reboot", result.stdout)
        self.assertNotIn("activate the newer installed kernel", result.stdout)
        self.assertEqual([c["kind"] for c in calls].count("reboot"), 1)

    def test_reboot_marker_without_newer_kernel_has_no_kernel_notice(self):
        result, calls = self.invoke(
            FORGE_TEST_REBOOT_STATE="yes",
            FORGE_TEST_KERNEL_UPDATE="no",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("NOTICE: Proxmox host reboot", result.stdout)
        self.assertNotIn("activate the newer installed kernel", result.stdout)
        self.assertIn("Overall result: SUCCESS", result.stdout)
        self.assertEqual([c["kind"] for c in calls].count("reboot"), 1)

    def test_host_detector_failure_is_nonfatal(self):
        result, calls = self.invoke(FORGE_TEST_REBOOT_FAIL="42")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot_required=unknown", result.stdout)
        self.assertIn("WARNING: could not determine host reboot", result.stderr)
        self.assertEqual([c["kind"] for c in calls].count("os"), 1)

    def test_held_detection_failure_is_nonfatal(self):
        result, calls = self.invoke(FORGE_TEST_HELD_FAIL="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["kind"] for c in calls].count("held"), 1)
        self.assertEqual([c["kind"] for c in calls].count("os"), 1)
        self.assertIn("WARNING: could not inspect held APT packages", result.stderr)

    def test_failed_host_update_does_not_run_reboot_postflight(self):
        result, calls = self.invoke(FORGE_TEST_OS_FAIL="42")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn("reboot", [c["kind"] for c in calls])
        self.assertIn("held", [c["kind"] for c in calls])
        self.assertIn("update=failed type=host", result.stdout)
        self.assertIn("result_target type=host vmid=HOST name=bv.deulo.com selected=true attempted=true status=ERROR reason=update_failed exit_code=42 apt_upgraded=1", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
