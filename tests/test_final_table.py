#!/usr/bin/env python3
"""F225/F226: renderer regression matrix without Proxmox or mutating commands."""

import os
import re
import subprocess
import unittest
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
RENDERER = ROOT / "lib/results/table.py"
HEADER = "VMID | Name | APT | Application version | Changelog | Result"


def record(vmid="101", name="pihole", status="OK", reason="completed",
           selected=True, attempted=True, apt="0", before="v6.4.3",
           after="v6.4.3", url="https://github.com/pi-hole/pi-hole",
           detail="OK", exit_code="", recovery="-", stage="-", type_="lxc"):
    data = {
        "type": type_, "vmid": vmid, "name": name,
        "selected": str(selected).lower(), "attempted": str(attempted).lower(),
        "status": status, "reason": reason,
        "apt_upgraded": apt, "app_before": before, "app_after": after,
        "app_repository": url, "failed_stage": stage, "recovery": recovery,
        "result_detail": quote(detail, safe=""),
    }
    if exit_code != "":
        data["exit_code"] = str(exit_code)
    return "result_target " + " ".join(f"{key}={value}" for key, value in data.items())


class ConsoleTableTests(unittest.TestCase):
    def assert_compact_row(self, output, vmid, name, apt, app):
        expected = (rf"(?m)^{re.escape(vmid)}\s+\|\s+{re.escape(name)}"
                    rf"\s+\|\s+{re.escape(apt)}\s+\|\s+"
                    rf"{re.escape(app)}\s+\|")
        self.assertRegex(output, expected)

    def render(self, records, width=110, color="never", **env):
        data = "\n".join(records) + "\n"
        return subprocess.run(
            ["python3", str(RENDERER)],
            input=data, capture_output=True, text=True,
            env={**os.environ, "FORGE_TABLE_WIDTH": str(width),
                 "FORGE_TABLE_COLOR": color, **env},
        )

    def test_empty_inventory_has_one_header_and_exact_zero_totals(self):
        out = self.render([])
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual(out.stdout.count("Forge final results"), 1)
        self.assertIn(HEADER, out.stdout)
        self.assertIn("Totals: targets=0 selected=0 attempted=0 "
                      "OK=0 ERROR=0 SKIPPED=0 NOT_RUN=0", out.stdout)

    def test_single_host_only_is_not_marked_as_a_guest(self):
        host = record(vmid="HOST", type_="host", name="bv.deulo.com",
                      apt="12", before="-", after="-", url="-")
        result = self.render([host])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_compact_row(result.stdout, "HOST", "bv.deulo.com", "12", "—")
        self.assertNotIn("Changelog links:", result.stdout)
        self.assertIn("Totals: targets=1 selected=1 attempted=1 "
                      "OK=1 ERROR=0 SKIPPED=0 NOT_RUN=0", result.stdout)

    def test_all_four_outcomes_preserve_causes_and_authoritative_totals(self):
        data = [
            record(vmid="9", name="old", status="SKIPPED", reason="stopped",
                   selected=False, attempted=False, apt="-", before="-",
                   after="-", url="-", detail="SKIPPED: container is stopped"),
            record(vmid="10", name="ok", apt="3"),
            record(vmid="100", name="failed", status="ERROR",
                   reason="update_failed", exit_code="42", stage="os_update",
                   recovery="success", detail="ERROR: os_update (exit 42); recovery succeeded"),
            record(vmid="111", name="blocked", status="NOT_RUN",
                   reason="host_update_failed", attempted=False,
                   apt="-", before="-", after="-", url="-",
                   detail="NOT RUN: host update failed"),
        ]
        r = self.render(data)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ERROR: os_update (exit 42); recovery succeeded", r.stdout)
        self.assertIn("SKIPPED: container is stopped", r.stdout)
        self.assertIn("NOT RUN: host update failed", r.stdout)
        self.assert_compact_row(r.stdout, "9", "old", "—", "—")
        self.assert_compact_row(r.stdout, "10", "ok", "3", "v6.4.3")
        self.assert_compact_row(r.stdout, "100", "failed", "0", "v6.4.3")
        self.assertLess(r.stdout.index("9  "), r.stdout.index("10 "))
        self.assertLess(r.stdout.index("10 "), r.stdout.index("100"))
        self.assertLess(r.stdout.index("100"), r.stdout.index("111"))
        self.assertIn("Totals: targets=4 selected=3 attempted=2 "
                      "OK=1 ERROR=1 SKIPPED=1 NOT_RUN=1", r.stdout)

    def test_application_unchanged_changed_and_undetectable(self):
        r = self.render([
            record(vmid="100", name="unchanged", before="2.0", after="2.0"),
            record(vmid="101", name="changed", before="1.0", after="3.0"),
            record(vmid="102", name="unknown", before="-", after="-", url="-", apt="-"),
        ])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assert_compact_row(r.stdout, "100", "unchanged", "0", "2.0")
        self.assert_compact_row(r.stdout, "101", "changed", "0", "1.0 → 3.0")
        self.assert_compact_row(r.stdout, "102", "unknown", "—", "—")
        self.assertIn("Changelog: https://github.com/pi-hole/pi-hole", r.stdout)
        self.assertEqual(r.stdout.count("Changelog: https://github.com/pi-hole/pi-hole"), 1)

    def test_unknown_app_does_not_invent_a_repository_or_zero_apt(self):
        r = self.render([record(apt="-", before="-", after="-", url="-")])
        self.assert_compact_row(r.stdout, "101", "pihole", "—", "—")
        self.assertNotIn("Changelog links:", r.stdout)

    def test_recovery_failure_and_warning_remain_in_result_not_status(self):
        r = self.render([
            record(vmid="100", status="ERROR", reason="update_failed",
                   exit_code="12", stage="application_update", recovery="failed:5",
                   detail="ERROR: application_update (exit 12); recovery failed (exit 5)"),
            record(vmid="101", detail="OK; WARNING: fstrim failed (exit 8)"),
        ])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ERROR: application_update (exit 12); recovery failed (exit 5)", r.stdout)
        self.assertIn("OK; WARNING: fstrim failed (exit 8)", r.stdout)
        self.assertIn("OK=1 ERROR=1", r.stdout)

    def test_multiline_untrusted_terminal_control_is_inert(self):
        diag = "ERROR: command failed\nstatus=OK\t\033[31mFAKE\033[0m\x07"
        r = self.render([record(detail=diag)], width=88)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("\x1b", r.stdout)
        self.assertNotIn("\x07", r.stdout)
        self.assertIn(" ⏎ ", r.stdout)
        self.assertIn("status=OK", r.stdout)
        self.assertIn("FAKE", r.stdout)
        self.assertIn("OK=1 ERROR=0", r.stdout)

    def test_wide_table_preserves_full_repository_and_wraps_long_diagnostics(self):
        link = "https://github.com/" + "longusername" * 4 + "/very-long-repository-name"
        message = "ERROR: " + "cannot resolve dependency " * 12
        r = self.render([
            record(name="long-container-name-requiring-overflow",
                   url=link, detail=message,
                   status="ERROR", reason="update_failed", exit_code="2"),
        ], width=205)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(HEADER[0:4], r.stdout)
        # Both the full URL and each individual word of the diagnostic survive.
        self.assertIn(link, r.stdout)
        self.assertEqual(r.stdout.count("Forge final results"), 1)
        self.assertIn("dependency", r.stdout)

    def test_narrow_terminal_keeps_full_url_and_result_readable(self):
        link = "https://github.com/" + "very-long-organization-name/" + "long-project-name"
        r = self.render([record(url=link, detail="ERROR: " + "failure " * 25)],
                        width=72)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Changelog: " + link, r.stdout)
        self.assertIn("VMID |", r.stdout)
        self.assertIn("-+-", r.stdout)
        self.assertIn("| Result", r.stdout)
        self.assertIn("Changelog links:", r.stdout)
        self.assertNotIn("\x1b", r.stdout)

    def test_compact_grid_is_aligned_and_width_bounded(self):
        rows = [
            record(vmid="HOST", type_="host", name="bv.deulos.com",
                   apt="2", before="-", after="-", url="-"),
            record(vmid="104", name="immich", apt="5",
                   before="3.3.0", after="3.3.1",
                   url="https://github.com/immich-app/immich"),
            record(vmid="110", name="whisparr", status="SKIPPED",
                   reason="stopped", selected=False, attempted=False,
                   apt="-", before="-", after="-", url="-",
                   detail="SKIPPED: container is stopped"),
        ]
        for width in (60, 72, 80, 100, 110, 120, 165):
            with self.subTest(width=width):
                result = self.render(rows, width=width)
                self.assertEqual(result.returncode, 0, result.stderr)
                content = result.stdout.split("Forge final results", 1)[1]
                grid = content.split("Changelog links:", 1)[0].splitlines()
                header = next(line for line in grid if line.startswith("VMID"))
                separator = next(line for line in grid if "-+-" in line)
                self.assertEqual(len(header), len(separator))
                self.assertLessEqual(len(header), width)
                self.assertEqual(header.count("|"), 5)
                self.assertEqual(separator.count("+"), 5)
                self.assertIn("Changelog: https://github.com/immich-app/immich",
                              result.stdout)
                self.assertIn("Overall result: SUCCESS", result.stdout)
                self.assertIn("targets=3 selected=2 attempted=2", result.stdout)
                for line in grid:
                    if line and not line.startswith("Totals:"):
                        self.assertLessEqual(len(line), width, line)

    def test_compact_url_references_are_unique_and_keep_full_clickable_links(self):
        url = "https://github.com/" + "very-long-organization/" * 3 + "repository"
        records = [
            record(vmid="100", url=url),
            record(vmid="101", url=url),
            record(vmid="102", url="https://github.com/pi-hole/pi-hole"),
        ]
        r = self.render(records, width=100)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Changelog links:", r.stdout)
        self.assertEqual(r.stdout.count("Changelog: " + url), 1)
        self.assertEqual(r.stdout.count("Changelog: https://github.com/pi-hole/pi-hole"), 1)
        self.assertEqual(r.stdout.count("[1]"), 3)  # 2 rows and footnote
        self.assertEqual(r.stdout.count("[2]"), 2)  # 1 row and footnote
        self.assertEqual(r.stdout.count("Forge final results"), 1)

    def test_terminal_color_automatic_and_no_color_plain(self):
        data = [record(status="ERROR", reason="update_failed", exit_code="2",
                       detail="ERROR: operation stopped")]
        plain = self.render(data, color="auto")
        self.assertNotIn("\x1b[", plain.stdout)
        forced = self.render(data, color="always")
        self.assertIn("\x1b[31m", forced.stdout)
        no_color = self.render(data, color="always", NO_COLOR="1")
        self.assertNotIn("\x1b[", no_color.stdout)

    def test_invalid_or_duplicate_records_do_not_silently_give_incorrect_totals(self):
        valid = record()
        invalid = [
            valid + " vmid=999",
            valid.replace("status=OK", "status=UNKNOWN"),
            valid.replace("vmid=101", "vmid=unknown"),
            valid.replace("result_detail=OK", "result_detail=FAIL%XX"),
            valid.replace("attempted=true", "attempted=unknown"),
            "result_target type=lxc vmid=101",
        ]
        for item in invalid:
            with self.subTest(item=item[-50:]):
                r = self.render([item])
                self.assertEqual(r.returncode, 2)
                self.assertIn("cannot render final results", r.stderr)
                self.assertNotIn("Totals:", r.stdout)

    def test_plain_unrelated_log_lines_are_not_interpreted_as_results(self):
        r = self.render([
            "update_all=failed stage=lxc exit_code=1",
            "WARNING: something happened",
            record(),
        ])
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Totals: targets=1 ", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
