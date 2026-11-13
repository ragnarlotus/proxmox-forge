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
    expected = [os.environ["FORGE_TEST_RUNNING_LXC"], os.environ["FORGE_TEST_EXCLUDE"]]
    if len(args) == 3:
        authorized = os.environ["FORGE_TEST_SCHEDULED_LXC"]
        expected = ["true" if authorized else "false", expected[1], authorized]
    elif os.environ.get("FORGE_TEST_EXPLICIT_INVENTORY") == "true":
        expected = ["true", ""]
    if args != expected:
        sys.exit("unexpected inventory policy")
    vmids = os.environ.get("FORGE_TEST_INVENTORY_VMIDS", os.environ["FORGE_TEST_VMIDS"])
    excluded = {x.strip() for x in args[1].split(",") if x.strip()}
    authorized = ({x.strip() for x in args[2].split(",") if x.strip()}
                  if len(args) == 3 else None)
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
        elif authorized is not None and vmid not in authorized:
            policy = "scheduled_not_authorized"
        elif args[0] == "false":
            policy = "running_lxc_disabled"
        else:
            policy = "eligible"
        state = "stopped" if vmid in stopped else "running"
        print(f"{vmid}\t{name}\t{state}\t{policy}")
    sys.exit(0)

with Path(os.environ["FORGE_TEST_CALLS"]).open("a") as log:
    log.write(json.dumps({"kind": kind, "args": args,
                          "backup_only": os.environ.get("FORGE_LXC_BACKUP_PREFLIGHT_OK", "")}) + "\n")

if kind == "list":
    expected = [os.environ["FORGE_TEST_RUNNING_LXC"], os.environ["FORGE_TEST_EXCLUDE"]]
    if len(args) == 3:
        authorized = os.environ["FORGE_TEST_SCHEDULED_LXC"]
        expected = ["true" if authorized else "false", expected[1], authorized]
    if args != expected:
        sys.exit("unexpected selection policy")
    if args[0] == "true":
        if os.environ.get("FORGE_TEST_MALFORMED_TARGET") == "true":
            print("type=lxc name=missing_id state=running template=false")
        else:
            exclusions = {value.strip() for value in args[1].split(",") if value.strip()}
            scheduled = ({x.strip() for x in args[2].split(",") if x.strip()}
                         if len(args) == 3 else None)
            for vmid in filter(None, os.environ["FORGE_TEST_VMIDS"].split(",")):
                if vmid in exclusions or f"guest{vmid}" in exclusions:
                    continue
                if scheduled is not None and vmid not in scheduled:
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
elif kind == "host":
    if os.environ.get("FORGE_RESULT_DETAIL_FILE"):
        detail, stage, recovery = json.loads(
            os.environ.get("FORGE_TEST_HOST_DETAIL", '["OK", "-", "-"]')
        )
        platform = os.environ.get("FORGE_TEST_HOST_PLATFORM", "-")
        Path(os.environ["FORGE_RESULT_DETAIL_FILE"]).write_text(
            f"{detail}\t{stage}\t{recovery}\t{platform}\n"
        )
    if os.environ.get("FORGE_APT_RESULT_FILE"):
        Path(os.environ["FORGE_APT_RESULT_FILE"]).write_text(
            os.environ.get("FORGE_TEST_HOST_APT", "3") + "\n"
        )
    code = int(os.environ.get("FORGE_TEST_HOST_CODE", "0"))
    print(f"update={'success' if code == 0 else 'failed'} type=host")
    sys.exit(code)
elif kind == "lxc":
    if os.environ.get("FORGE_RESULT_DETAIL_FILE"):
        details = json.loads(os.environ.get("FORGE_TEST_LXC_DETAIL", "{}"))
        detail, stage, recovery = details.get(args[0], ["OK", "-", "-"])
        Path(os.environ["FORGE_RESULT_DETAIL_FILE"]).write_text(
            f"{detail}\t{stage}\t{recovery}\t-\n"
        )
    if os.environ.get("FORGE_APP_RESULT_FILE"):
        versions = json.loads(os.environ.get("FORGE_TEST_LXC_APP", "{}"))
        before, after, repository = versions.get(args[0], ["-", "-", "-"])
        Path(os.environ["FORGE_APP_RESULT_FILE"]).write_text(
            f"{before}\t{after}\t{repository}\n"
        )
    if os.environ.get("FORGE_APT_RESULT_FILE"):
        counts = json.loads(os.environ.get("FORGE_TEST_LXC_APT", "{}"))
        Path(os.environ["FORGE_APT_RESULT_FILE"]).write_text(
            str(counts.get(args[0], 0)) + "\n"
        )
    if len(args) != 2 or args[1] not in ("scope", "explicit"):
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
            "results/table.py": None,
            "notifications/send.py": None,
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
                    '    [SCHEDULED_UPDATE_HOST]="${FORGE_TEST_SCHEDULED_HOST:-false}"\n'
                    '    [SCHEDULED_UPDATE_LXC]="${FORGE_TEST_SCHEDULED_LXC:-}"\n'
                    '    [EMAIL_NOTIFICATIONS]="${FORGE_TEST_EMAIL_NOTIFICATIONS:-false}"\n'
                    '    [NOTIFY_MANUAL]="${FORGE_TEST_NOTIFY_MANUAL:-errors}"\n'
                    '    [NOTIFY_SCHEDULED]="${FORGE_TEST_NOTIFY_SCHEDULED:-all}"\n'
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
            "FORGE_TEST_EMAIL_NOTIFICATIONS": "false",
            "FORGE_TEST_NOTIFY_MANUAL": "errors",
            "FORGE_TEST_NOTIFY_SCHEDULED": "all",
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

    @staticmethod
    def inventory(result):
        records = []
        for line in result.stdout.splitlines():
            if line.startswith("result_target "):
                records.append(dict(field.split("=", 1) for field in line.split()[1:]))
        return records

    def test_host_kernel_reboot_notice_appears_in_combined_final_table(self):
        from urllib.parse import quote, unquote
        message = (
            "OK; WARNING: reboot the Proxmox host to activate "
            "the newer installed kernel"
        )
        result, _ = self.invoke(
            "all",
            FORGE_TEST_HOST_DETAIL=json.dumps([quote(message, safe=""), "-", "-"]),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.inventory(result)
        self.assertEqual(rows[0]["status"], "OK")
        self.assertEqual(unquote(rows[0]["result_detail"]), message)
        self.assertIn("activate the newer installed kernel", result.stdout)
        self.assertIn("Overall result: SUCCESS", result.stdout)
        self.assertEqual(result.stdout.count("Forge final results"), 1)

    def test_host_platform_metadata_survives_bulk_handoff(self):
        from urllib.parse import quote, unquote
        platform = (
            "Proxmox VE 9.0.11; Debian 13; Kernel running 7.0.14-25-pve; "
            "Latest installed kernel 7.0.14-26-pve"
        )
        result, _ = self.invoke(
            "all",
            FORGE_TEST_HOST_PLATFORM=quote(platform, safe=""),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.inventory(result)
        self.assertEqual(rows[0]["type"], "host")
        self.assertEqual(unquote(rows[0]["host_platform"]), platform)
        self.assertIn("Proxmox VE 9.0.11", result.stdout)
        self.assertIn("Debian 13", result.stdout)
        self.assertIn("Kernel running", result.stdout)
        self.assertEqual(rows[1]["host_platform"], "-")

    def test_f225_final_table_exactly_once_across_success_failures_and_blockers(self):
        scenarios = [
            ("lxc", {}, 0, 3, 0),
            ("all", {}, 0, 4, 0),
            ("lxc", {"FORGE_TEST_VMIDS": ""}, 0, 0, 0),
            ("all", {"FORGE_TEST_LXC_CODES": json.dumps({"111": 42})}, 1, 4, 1),
            ("all", {"FORGE_TEST_HOST_CODE": "42"}, 42, 4, 1),
            ("all", {"FORGE_TEST_CONFLICT": "true"}, 1, 4, 0),
            ("all", {"FORGE_TEST_RUNNING_LXC": "false"}, 0, 4, 0),
            ("all", {"FORGE_TEST_RUNNING_LXC": "false",
                     "FORGE_TEST_UPDATE_HOST": "false"}, 0, 4, 0),
            ("all", {"FORGE_TEST_EXCLUDE": "111,115"}, 0, 4, 0),
            ("lxc", {"FORGE_TEST_VMIDS": "",
                     "FORGE_TEST_INVENTORY_VMIDS": "100,111,115",
                     "FORGE_TEST_STOPPED_VMIDS": "100,111,115"}, 0, 3, 0),
            ("lxc", {"FORGE_TEST_VMIDS": "111,115",
                     "FORGE_TEST_INVENTORY_VMIDS": "100,111,115",
                     "FORGE_TEST_TEMPLATE_VMIDS": "100"}, 0, 3, 0),
            ("all", {"FORGE_TEST_LXC_CODES": json.dumps({
                "100": 2, "111": 3, "115": 4})}, 1, 4, 3),
            ("lxc", {"FORGE_TEST_VMIDS": "100,115",
                     "FORGE_TEST_INVENTORY_VMIDS": "100,111,115",
                     "FORGE_TEST_STOPPED_VMIDS": "111"}, 0, 3, 0),
            ("lxc", {"FORGE_TEST_LXC_CODES": json.dumps({
                "100": 22, "111": 33, "115": 44})}, 1, 3, 3),
        ]
        for mode, options, exit_code, target_count, error_count in scenarios:
            with self.subTest(mode=mode, options=options):
                result, calls = self.invoke(mode, **options)
                self.assertEqual(result.returncode, exit_code, result.stderr)
                rows = self.inventory(result)
                self.assertEqual(len(rows), target_count)
                self.assertEqual(result.stdout.count("Forge final results"), 1)
                self.assertEqual(result.stdout.count("Totals: targets="), 1)
                self.assertIn(
                    f"\n\nTotals: targets={target_count} ", result.stdout
                )
                self.assertIn(
                    f"ERROR={error_count} ", result.stdout
                )
                for row in rows:
                    self.assertIn(row["name"], result.stdout)
                self.assertEqual(
                    len([c for c in calls if c["kind"] == "lxc"]),
                    sum(row["attempted"] == "true" for row in rows
                        if row["type"] == "lxc"),
                )
                self.assertNotIn("\033[", result.stdout)

    def test_f225_bulk_table_propagates_real_metadata_and_result_details(self):
        result, calls = self.invoke(
            "all",
            FORGE_TEST_LXC_APP=json.dumps({
                "100": ["v1.0", "v1.2", "https://github.com/pi-hole/pi-hole"],
                "111": ["v2.0", "v2.0", "https://github.com/docmost/docmost"],
                "115": ["-", "-", "-"],
            }),
            FORGE_TEST_LXC_APT=json.dumps({"100": 4, "111": 0, "115": 0}),
            FORGE_TEST_LXC_CODES=json.dumps({"111": 42}),
            FORGE_TEST_LXC_DETAIL=json.dumps({
                "111": [
                    "ERROR%3A%20application_update%20%28exit%2042%29%3B%20recovery%20succeeded",
                    "application_update", "success"
                ],
            }),
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stdout.count("Forge final results"), 1)
        self.assertRegex(result.stdout, r"(?m)^100\s+\|\s+guest100\s+\|\s+4\s+\|\s+v1\.0 → v1\.2\s+\|")
        self.assertRegex(result.stdout, r"(?m)^111\s+\|\s+guest111\s+\|\s+0\s+\|\s+v2\.0\s+\|")
        self.assertIn("Changelog: https://github.com/pi-hole/pi-hole", result.stdout)
        self.assertNotIn("Changelog: https://github.com/docmost/docmost", result.stdout)
        self.assertIn("ERROR: application_update (exit 42); recovery succeeded", result.stdout)
        self.assertIn("Totals: targets=4 selected=4 attempted=4 "
                      "OK=3 ERROR=1 SKIPPED=0 NOT_RUN=0", result.stdout)
        self.assertEqual(
            [c["args"][0] for c in calls if c["kind"] == "lxc"],
            ["100", "111", "115"]
        )

    def test_f222_bulk_keeps_app_versions_and_excludes_skipped_guests(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_LXC_APP=json.dumps({
                "100": ["1.0", "1.2", "-"], "111": ["3.0", "3.0", "-"],
            }), FORGE_TEST_EXCLUDE="115",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.inventory(result)
        self.assertEqual([(r["vmid"], r["app_before"], r["app_after"]) for r in rows], [
            ("HOST", "-", "-"),
            ("100", "1.0", "1.2"),
            ("111", "3.0", "3.0"),
            ("115", "-", "-"),
        ])
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"], ["100", "111"])

    def test_f224_mixed_host_lxc_failure_details_and_skips(self):
        result, calls = self.invoke(
            "all",
            FORGE_TEST_LXC_CODES=json.dumps({"111": 42}),
            FORGE_TEST_LXC_DETAIL=json.dumps({
                "111": [
                    "ERROR%3A%20application_update%20%28exit%2042%29%3B%20recovery%20failed%20%28exit%2043%29",
                    "application_update", "failed:43",
                ],
            }),
            FORGE_TEST_EXCLUDE="115",
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        rows = self.inventory(result)
        self.assertEqual(
            [(r["vmid"], r["status"], r["failed_stage"], r["recovery"]) for r in rows],
            [
                ("HOST", "OK", "-", "-"),
                ("100", "OK", "-", "-"),
                ("111", "ERROR", "application_update", "failed:43"),
                ("115", "SKIPPED", "-", "-"),
            ],
        )
        self.assertEqual(
            rows[2]["result_detail"],
            "ERROR%3A%20application_update%20%28exit%2042%29%3B%20recovery%20failed%20%28exit%2043%29",
        )
        self.assertEqual(
            [c["args"][0] for c in calls if c["kind"] == "lxc"], ["100", "111"],
        )

    def test_bulk_lxc_four_field_handoff_reports_health_and_backup_failures(self):
        # Reproduces the actual record.sh format: detail, stage, recovery,
        # host_platform="-". The old three-field reader swallowed the last
        # column into recovery and silently displayed "ERROR: unknown".
        result, _ = self.invoke(
            "lxc",
            FORGE_TEST_LXC_CODES=json.dumps({"100": 1, "111": 1}),
            FORGE_TEST_LXC_DETAIL=json.dumps({
                "100": [
                    "ERROR%3A%20health%20%28exit%201%29%3A%20logrotate.service%20failed%3B%20recovery%20succeeded",
                    "health", "success",
                ],
                "111": [
                    "ERROR%3A%20backup%20%28exit%201%29%3A%20multiple%20new%20volumes%3B%20recovery%20unavailable%20%28no%20artifact%29",
                    "backup", "unavailable",
                ],
            }),
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        rows = {row["vmid"]: row for row in self.inventory(result)}
        self.assertEqual((rows["100"]["failed_stage"], rows["100"]["recovery"]),
                         ("health", "success"))
        self.assertEqual((rows["111"]["failed_stage"], rows["111"]["recovery"]),
                         ("backup", "unavailable"))
        self.assertIn("ERROR: health (exit 1): logrotate.service failed", result.stdout)
        self.assertIn("ERROR: backup (exit 1): multiple new volumes", result.stdout)
        self.assertNotIn("ERROR: unknown", result.stdout)

    def test_f224_preflight_not_run_includes_known_blocking_guest(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_LOW_SPACE_VMID="111",
        )
        self.assertNotEqual(result.returncode, 0)
        rows = self.inventory(result)
        self.assertTrue(all(r["status"] == "NOT_RUN" for r in rows))
        self.assertTrue(all(
            "LXC%20111%20root%20space%20preflight%20failed" in r["result_detail"]
            for r in rows[1:]
        ))
        self.assertNotIn("lxc", [c["kind"] for c in calls])

    def test_f224_host_failure_handoff_preserves_host_error_and_guest_results(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_HOST_CODE="42",
            FORGE_TEST_HOST_DETAIL=json.dumps([
                "ERROR%3A%20os_update%20%28exit%2042%29", "os_update", "-",
            ]),
        )
        self.assertEqual(result.returncode, 42)
        rows = self.inventory(result)
        self.assertEqual(rows[0]["failed_stage"], "os_update")
        self.assertEqual(rows[0]["result_detail"], "ERROR%3A%20os_update%20%28exit%2042%29")
        self.assertTrue(all(
            r["status"] == "OK" and r["reason"] == "completed"
            for r in rows[1:]
        ))
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111", "115"])
        self.assertIn("result_global status=PARTIAL", result.stdout)

    def test_f223_repo_present_when_unchanged_or_version_unknown_in_bulk(self):
        result, calls = self.invoke(
            "all",
            FORGE_TEST_LXC_APP=json.dumps({
                "100": ["1.0", "1.0", "https://github.com/pi-hole/pi-hole"],
                "111": ["-", "-", "https://github.com/Whisparr/Whisparr"],
                "115": ["2.0", "2.1", "-"],
            }),
            FORGE_TEST_LXC_CODES=json.dumps({"111": 42}),
            FORGE_TEST_EXCLUDE="115",
        )
        self.assertEqual(result.returncode, 1)
        rows = self.inventory(result)
        self.assertEqual(
            [(row["vmid"], row["app_repository"], row["status"]) for row in rows],
            [
                ("HOST", "-", "OK"),
                ("100", "https://github.com/pi-hole/pi-hole", "OK"),
                ("111", "https://github.com/Whisparr/Whisparr", "ERROR"),
                ("115", "-", "SKIPPED"),
            ],
        )
        self.assertEqual(
            [c["args"][0] for c in calls if c["kind"] == "lxc"],
            ["100", "111"],
        )

    def test_f223_malformed_bulk_repo_does_not_discard_valid_versions(self):
        result, calls = self.invoke(
            FORGE_TEST_LXC_APP=json.dumps({
                "100": ["1.0", "2.0", "https://malicious.example/hello"],
                "111": ["-", "-", "-"],
                "115": ["-", "-", "-"],
            }),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.inventory(result)
        self.assertEqual(rows[0]["app_repository"], "-")
        self.assertEqual(
            (rows[0]["app_before"], rows[0]["app_after"]), ("1.0", "2.0")
        )
        self.assertEqual(
            [c["args"][0] for c in calls if c["kind"] == "lxc"],
            ["100", "111", "115"],
        )

    def test_f221_bulk_records_keep_per_target_measured_apt_values(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_HOST_APT="12",
            FORGE_TEST_LXC_APT=json.dumps({"100": 0, "111": 4, "115": 2}),
            FORGE_TEST_LXC_CODES=json.dumps({"111": 42}),
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        rows = self.inventory(result)
        self.assertEqual(
            [(row["vmid"], row["apt_upgraded"]) for row in rows],
            [("HOST", "12"), ("100", "0"), ("111", "4"), ("115", "2")],
        )
        self.assertEqual(rows[2]["exit_code"], "42")
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111", "115"])

    def test_f221_all_skipped_have_unattempted_apt_counts(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_RUNNING_LXC="false", FORGE_TEST_UPDATE_HOST="false",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.inventory(result)
        self.assertTrue(all(r["apt_upgraded"] == "-" for r in rows))
        self.assertNotIn("host", [c["kind"] for c in calls])
        self.assertNotIn("lxc", [c["kind"] for c in calls])

    def test_f221_skipped_and_blocked_targets_have_unknown_count(self):
        result, _ = self.invoke(
            "all", FORGE_TEST_HOST_CODE="42",
            FORGE_TEST_STOPPED_VMIDS="113",
            FORGE_TEST_INVENTORY_VMIDS="100,111,113,115",
        )
        self.assertEqual(result.returncode, 42)
        rows = self.inventory(result)
        self.assertEqual(rows[0]["apt_upgraded"], "3")
        self.assertEqual([r["apt_upgraded"] for r in rows[1:]], ["0", "0", "-", "0"])

    def test_f220_mixed_inventory_order_and_skip_reasons(self):
        result, calls = self.invoke(
            FORGE_TEST_INVENTORY_VMIDS="120,115,113,111,100,10,9",
            FORGE_TEST_STOPPED_VMIDS="113,9,10",
            FORGE_TEST_TEMPLATE_VMIDS="120",
            FORGE_TEST_EXCLUDE="115",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.inventory(result)
        self.assertEqual([r["vmid"] for r in rows],
                         ["9", "10", "100", "111", "113", "115", "120"])
        self.assertEqual([(r["vmid"], r["status"], r["reason"]) for r in rows], [
            ("9", "SKIPPED", "stopped"),
            ("10", "SKIPPED", "stopped"),
            ("100", "OK", "completed"),
            ("111", "OK", "completed"),
            ("113", "SKIPPED", "stopped"),
            ("115", "SKIPPED", "excluded"),
            ("120", "SKIPPED", "template"),
        ])
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111"])

    def test_f220_host_failure_does_not_block_selected_lxcs(self):
        result, calls = self.invoke("all", FORGE_TEST_HOST_CODE="42")
        self.assertEqual(result.returncode, 42)
        rows = self.inventory(result)
        self.assertEqual(rows[0]["status"], "ERROR")
        self.assertEqual(rows[0]["exit_code"], "42")
        self.assertEqual([r["status"] for r in rows[1:]], ["OK", "OK", "OK"])
        self.assertTrue(all(r["reason"] == "completed" for r in rows[1:]))
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111", "115"])
        self.assertIn("result_global status=PARTIAL", result.stdout)

    def test_f220_preflight_blocked_marks_host_and_eligible_guests_not_run(self):
        result, calls = self.invoke("all", FORGE_TEST_CONFLICT="true")
        self.assertNotEqual(result.returncode, 0)
        rows = self.inventory(result)
        self.assertEqual([r["status"] for r in rows],
                         ["NOT_RUN", "NOT_RUN", "NOT_RUN", "NOT_RUN"])
        self.assertTrue(all(r["reason"] == "preflight_blocked" for r in rows))
        self.assertNotIn("host", [c["kind"] for c in calls])

    def test_f220_disabled_running_scope_and_host_disabled(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_RUNNING_LXC="false", FORGE_TEST_UPDATE_HOST="false"
        )
        self.assertEqual(result.returncode, 0)
        rows = self.inventory(result)
        self.assertEqual(rows[0]["status"], "SKIPPED")
        self.assertEqual(rows[0]["reason"], "host_disabled")
        self.assertEqual([r["status"] for r in rows[1:]],
                         ["SKIPPED", "SKIPPED", "SKIPPED"])
        self.assertTrue(all(r["reason"] == "running_lxc_disabled" for r in rows[1:]))
        self.assertNotIn("host", [c["kind"] for c in calls])

    def test_f220_selection_disagreement_fails_before_mutation(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_INVENTORY_VMIDS="100,111"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absent or not eligible", result.stderr)
        self.assertNotIn("host", [c["kind"] for c in calls])
        self.assertNotIn("lxc", [c["kind"] for c in calls])

    def test_f220_one_guest_failure_preserves_later_guest_results(self):
        result, calls = self.invoke(
            FORGE_TEST_LXC_CODES=json.dumps({"111": 42})
        )
        self.assertEqual(result.returncode, 1)
        rows = self.inventory(result)
        self.assertEqual([(r["status"], r.get("exit_code")) for r in rows],
                         [("OK", None), ("ERROR", "42"), ("OK", None)])
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111", "115"])

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

    def test_host_failure_preserves_code_and_continues_guest_updates(self):
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
            ("lxc", ["100", "scope"]),
            ("lxc", ["111", "scope"]),
            ("lxc", ["115", "scope"]),
        ])
        self.assertIn("update_all=failed stage=host exit_code=42 lxc_started=true lxc_succeeded=3 lxc_failed=0",
                      result.stdout)
        self.assertIn("Forge update summary: host FAILED (exit code 42); 3 LXCs selected, 3 succeeded, 0 failed; overall PARTIAL.", result.stdout)


    def test_host_failure_with_guest_failures_continues_and_preserves_first_error(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_HOST_CODE="42",
            FORGE_TEST_LXC_CODES=json.dumps({"111": 17}),
        )
        self.assertEqual(result.returncode, 42)
        self.assertEqual([c["args"][0] for c in calls if c["kind"] == "lxc"],
                         ["100", "111", "115"])
        self.assertEqual(
            [(r["vmid"], r["status"], r.get("exit_code")) for r in self.inventory(result)],
            [("HOST", "ERROR", "42"), ("100", "OK", None),
             ("111", "ERROR", "17"), ("115", "OK", None)],
        )
        self.assertIn("result_global status=PARTIAL", result.stdout)
        self.assertIn("lxc_succeeded=2 lxc_failed=1", result.stdout)

    def test_host_failure_with_disabled_lxc_scope_still_fails(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_HOST_CODE="42", FORGE_TEST_RUNNING_LXC="false",
        )
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("lxc", [c["kind"] for c in calls])
        self.assertEqual([r["status"] for r in self.inventory(result)],
                         ["ERROR", "SKIPPED", "SKIPPED", "SKIPPED"])
        self.assertIn("result_global status=FAILED", result.stdout)

    def test_host_failure_with_empty_running_scope_still_fails(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_HOST_CODE="42", FORGE_TEST_VMIDS="",
        )
        self.assertEqual(result.returncode, 42)
        self.assertNotIn("lxc", [c["kind"] for c in calls])
        self.assertEqual([r["status"] for r in self.inventory(result)], ["ERROR"])
        self.assertIn("result_global status=FAILED", result.stdout)

    def test_host_failure_with_all_guests_failed_is_not_partially_successful(self):
        result, calls = self.invoke(
            "all", FORGE_TEST_HOST_CODE="42",
            FORGE_TEST_LXC_CODES=json.dumps({"100": 4, "111": 5, "115": 6}),
        )
        self.assertEqual(result.returncode, 42)
        self.assertEqual(len([c for c in calls if c["kind"] == "lxc"]), 3)
        self.assertEqual([r["status"] for r in self.inventory(result)],
                         ["ERROR", "ERROR", "ERROR", "ERROR"])
        self.assertIn("result_global status=FAILED", result.stdout)

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

    def test_backup_only_preflight_applies_to_all_selected_guests(self):
        result, calls = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        updates = [c for c in calls if c["kind"] == "lxc"]
        self.assertEqual(len(updates), 3)
        self.assertTrue(all(c["backup_only"] == "true" for c in updates))
        self.assertNotIn("backup_fallback=", result.stdout)

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
