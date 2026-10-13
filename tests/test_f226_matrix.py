#!/usr/bin/env python3
"""F226: exercise F220-F225's real bulk coordinator, records and final renderer.

The only real production entrypoints used here are update-all.sh, record.sh and
table.py. The inherited fixture replaces every Proxmox, host, guest, package,
backup and recovery command with isolated test doubles.
"""

from collections import Counter
import json
import os
import re
import unittest
from urllib.parse import quote, unquote

from test_results import ResultAggregationTests


class FinalResultsMatrixTests(unittest.TestCase):
    # Reuse the established real-coordinator fixture without inheriting (and
    # consequently rerunning) its entire historical unittest test suite.
    setUp = ResultAggregationTests.setUp
    invoke = ResultAggregationTests.invoke
    inventory = staticmethod(ResultAggregationTests.inventory)

    @staticmethod
    def changes(calls, kind):
        return [call["args"][0] for call in calls if call["kind"] == kind]

    def assert_consistent(self, result, calls, expected, exit_code):
        """Compare every authoritative row against one printed table and calls."""
        self.assertEqual(result.returncode, exit_code, result.stderr)
        rows = self.inventory(result)
        self.assertEqual(
            [(r["vmid"], r["status"], r["reason"]) for r in rows],
            expected,
            result.stdout + result.stderr,
        )
        self.assertEqual(result.stdout.count("Forge final results"), 1)
        self.assertEqual(result.stdout.count("Totals: targets="), 1)
        self.assertNotIn("\033[", result.stdout)  # redirected/non-TTY output
        table = result.stdout.split("Forge final results", 1)[1]
        # Parse the actual six-column grid, including physical continuation
        # lines, so long FQDNs/versions cannot be dropped merely because they
        # no longer fit into one terminal line.
        text_lines = table.splitlines()
        separator = next(i for i, line in enumerate(text_lines) if "-+-" in line)
        displayed = []
        for line in text_lines[separator + 1:]:
            if "|" not in line:
                break  # links legend or totals
            parts = [part.strip() for part in line.split("|")]
            self.assertEqual(len(parts), 6, (line, table))
            if parts[0]:
                displayed.append([[] for _ in range(6)])
            else:
                self.assertTrue(displayed, "orphan continuation row")
            for idx, value in enumerate(parts):
                if value:
                    displayed[-1][idx].append(value)
        self.assertEqual(len(displayed), len(rows), table)
        for row, cells in zip(rows, displayed):
            self.assertEqual("".join(cells[0]), row["vmid"])
            self.assertEqual("".join(cells[1]), row["name"])
        for row in rows:
            status = row["status"]
            self.assertEqual(row["attempted"], str(status in ("OK", "ERROR")).lower())
            self.assertEqual(row["selected"], str(status not in ("SKIPPED",)).lower())
            self.assertEqual(
                "exit_code" in row, status == "ERROR",
                row,
            )
            if status in ("SKIPPED", "NOT_RUN"):
                self.assertEqual(row["apt_upgraded"], "-")
                self.assertEqual(
                    (row["app_before"], row["app_after"], row["app_repository"]),
                    ("-", "-", "-"),
                )
            else:
                self.assertRegex(row["apt_upgraded"], r"^(?:[0-9]+|-)$")
            displayed_apt = "—" if row["apt_upgraded"] == "-" else row["apt_upgraded"]
            before, after = row["app_before"], row["app_after"]
            displayed_app = (
                "—" if "-" in (before, after)
                else before if before == after
                else f"{before} → {after}"
            )
            cell = next(cells for cells in displayed if "".join(cells[0]) == row["vmid"])
            self.assertEqual("".join(cell[1]), row["name"])
            self.assertEqual("".join(cell[2]), displayed_apt)
            self.assertEqual(
                re.sub(r"\\s+", "", "".join(cell[3])),
                re.sub(r"\\s+", "", displayed_app),
            )
            detail = unquote(row["result_detail"])
            if status == "SKIPPED":
                self.assertTrue(detail.startswith("SKIPPED:"), detail)
            if status == "NOT_RUN":
                self.assertTrue(detail.startswith("NOT RUN:"), detail)
        self.assertEqual(
            ["".join(cells[0]) for cells in displayed],
            [row["vmid"] for row in rows],
            "wrong table row order",
        )
        counts = Counter(row["status"] for row in rows)
        selected = sum(row["selected"] == "true" for row in rows)
        attempted = sum(row["attempted"] == "true" for row in rows)
        expected_totals = (
            f"Totals: targets={len(rows)} selected={selected} attempted={attempted} "
            f'OK={counts["OK"]} ERROR={counts["ERROR"]} '
            f'SKIPPED={counts["SKIPPED"]} NOT_RUN={counts["NOT_RUN"]}'
        )
        self.assertEqual(table.count(expected_totals), 1, table)
        # F157 must use these same records, not the workflow's technical
        # success/failure line or a second independent guest counter.
        incomplete = counts["ERROR"] + counts["NOT_RUN"]
        outcome = ("PARTIAL" if counts["OK"] else "FAILED") if incomplete else "SUCCESS"
        expected_global = (
            f"result_global status={outcome} targets={len(rows)} "
            f"selected={selected} attempted={attempted} "
            f'succeeded={counts["OK"]} failed={counts["ERROR"]} '
            f'skipped={counts["SKIPPED"]} not_run={counts["NOT_RUN"]}'
        )
        global_records = [line for line in result.stdout.splitlines()
                          if line.startswith("result_global ")]
        self.assertEqual(global_records, [expected_global], result.stdout)
        self.assertEqual(result.stdout.count(f"Overall result: {outcome}"), 1)
        # F159 must summarize only the very same failed/blocked records;
        # a warning-only OK and an intentional SKIPPED target are never errors.
        affected = [row for row in rows
                    if row["status"] in ("ERROR", "NOT_RUN")]
        marker = "Failed and blocked targets ("
        if affected:
            self.assertEqual(result.stdout.count(marker), 1)
            digest = result.stdout.split(marker, 1)[1]
            self.assertTrue(digest.startswith(f"{len(affected)}):"), digest)
            for row in rows:
                heading = f'  {row["vmid"]} | {row["name"]} | {row["status"]}'
                self.assertEqual(
                    digest.count(heading),
                    int(row["status"] in ("ERROR", "NOT_RUN")),
                    digest,
                )
        else:
            self.assertNotIn(marker, result.stdout)
        expected_guest_calls = [r["vmid"] for r in rows
                                if r["type"] == "lxc" and r["attempted"] == "true"]
        self.assertEqual(self.changes(calls, "lxc"), expected_guest_calls)
        self.assertEqual(
            len([c for c in calls if c["kind"] == "host"]),
            sum(r["type"] == "host" and r["attempted"] == "true" for r in rows),
        )
        return rows, table

    def test_full_invocation_selection_and_outcome_matrix(self):
        # Each case asserts the entire row inventory, status/reason,
        # selection, attempt, APT measurement, ordered rendering and totals.
        tests = [
            ("no guests", "lxc", {"FORGE_TEST_VMIDS": ""}, 0, []),
            ("host only", "all", {"FORGE_TEST_VMIDS": ""}, 0,
             [("HOST", "OK", "completed")]),
            ("host disabled, no guests", "all",
             {"FORGE_TEST_VMIDS": "", "FORGE_TEST_UPDATE_HOST": "false"}, 0,
             [("HOST", "SKIPPED", "host_disabled")]),
            ("one guest", "lxc", {"FORGE_TEST_VMIDS": "9"}, 0,
             [("9", "OK", "completed")]),
            ("combined all succeed", "all", {}, 0,
             [("HOST", "OK", "completed"),
              ("100", "OK", "completed"), ("111", "OK", "completed"),
              ("115", "OK", "completed")]),
            ("one fails, later guest proceeds", "lxc",
             {"FORGE_TEST_LXC_CODES": '{"111":42}'}, 1,
             [("100", "OK", "completed"), ("111", "ERROR", "update_failed"),
              ("115", "OK", "completed")]),
            ("multiple failures", "lxc",
             {"FORGE_TEST_LXC_CODES": '{"100":17,"115":19}'}, 1,
             [("100", "ERROR", "update_failed"), ("111", "OK", "completed"),
              ("115", "ERROR", "update_failed")]),
            ("every guest fails, host succeeds", "all",
             {"FORGE_TEST_LXC_CODES": '{"100":9,"111":11,"115":13}'}, 1,
             [("HOST", "OK", "completed"),
              ("100", "ERROR", "update_failed"), ("111", "ERROR", "update_failed"),
              ("115", "ERROR", "update_failed")]),
            ("host fails before guests", "all",
             {"FORGE_TEST_HOST_CODE": "42"}, 42,
             [("HOST", "ERROR", "update_failed"),
              ("100", "NOT_RUN", "host_update_failed"),
              ("111", "NOT_RUN", "host_update_failed"),
              ("115", "NOT_RUN", "host_update_failed")]),
            ("preflight conflict", "all",
             {"FORGE_TEST_CONFLICT": "true"}, 1,
             [("HOST", "NOT_RUN", "preflight_blocked"),
              ("100", "NOT_RUN", "preflight_blocked"),
              ("111", "NOT_RUN", "preflight_blocked"),
              ("115", "NOT_RUN", "preflight_blocked")]),
            ("preflight low space", "all",
             {"FORGE_TEST_LOW_SPACE_VMID": "111"}, 1,
             [("HOST", "NOT_RUN", "preflight_blocked"),
              ("100", "NOT_RUN", "preflight_blocked"),
              ("111", "NOT_RUN", "preflight_blocked"),
              ("115", "NOT_RUN", "preflight_blocked")]),
            ("preflight low memory", "all",
             {"FORGE_TEST_LOW_MEMORY_VMID": "111"}, 1,
             [("HOST", "NOT_RUN", "preflight_blocked"),
              ("100", "NOT_RUN", "preflight_blocked"),
              ("111", "NOT_RUN", "preflight_blocked"),
              ("115", "NOT_RUN", "preflight_blocked")]),
            ("host disabled but guests update", "all",
             {"FORGE_TEST_UPDATE_HOST": "false"}, 0,
             [("HOST", "SKIPPED", "host_disabled"),
              ("100", "OK", "completed"), ("111", "OK", "completed"),
              ("115", "OK", "completed")]),
            ("guest scope disabled but host updates", "all",
             {"FORGE_TEST_RUNNING_LXC": "false"}, 0,
             [("HOST", "OK", "completed"),
              ("100", "SKIPPED", "running_lxc_disabled"),
              ("111", "SKIPPED", "running_lxc_disabled"),
              ("115", "SKIPPED", "running_lxc_disabled")]),
            ("both scopes disabled", "all",
             {"FORGE_TEST_RUNNING_LXC": "false",
              "FORGE_TEST_UPDATE_HOST": "false"}, 0,
             [("HOST", "SKIPPED", "host_disabled"),
              ("100", "SKIPPED", "running_lxc_disabled"),
              ("111", "SKIPPED", "running_lxc_disabled"),
              ("115", "SKIPPED", "running_lxc_disabled")]),
            ("all guests excluded", "lxc",
             {"FORGE_TEST_EXCLUDE": "100,guest111,115"}, 0,
             [("100", "SKIPPED", "excluded"),
              ("111", "SKIPPED", "excluded"),
              ("115", "SKIPPED", "excluded")]),
            ("mixed stopped, template, exclusion and numeric order", "all",
             {"FORGE_TEST_VMIDS": "100,111",
              "FORGE_TEST_INVENTORY_VMIDS": "120,113,111,100,10,9",
              "FORGE_TEST_STOPPED_VMIDS": "9,10,113",
              "FORGE_TEST_TEMPLATE_VMIDS": "120",
              "FORGE_TEST_EXCLUDE": "113,guest120"}, 0,
             [("HOST", "OK", "completed"),
              ("9", "SKIPPED", "stopped"),
              ("10", "SKIPPED", "stopped"),
              ("100", "OK", "completed"),
              ("111", "OK", "completed"),
              ("113", "SKIPPED", "stopped"),
              ("120", "SKIPPED", "template")]),
            ("host failure with skipped and blocked guests", "all",
             {"FORGE_TEST_HOST_CODE": "27", "FORGE_TEST_VMIDS": "100,115",
              "FORGE_TEST_INVENTORY_VMIDS": "100,111,113,115",
              "FORGE_TEST_STOPPED_VMIDS": "113",
              "FORGE_TEST_EXCLUDE": "guest111"}, 27,
             [("HOST", "ERROR", "update_failed"),
              ("100", "NOT_RUN", "host_update_failed"),
              ("111", "SKIPPED", "excluded"),
              ("113", "SKIPPED", "stopped"),
              ("115", "NOT_RUN", "host_update_failed")]),
        ]
        for label, mode, opts, code, expected in tests:
            with self.subTest(label=label):
                result, calls = self.invoke(
                    mode, FORGE_TABLE_WIDTH="110", FORGE_TABLE_COLOR="never",
                    **opts,
                )
                self.assert_consistent(result, calls, expected, code)
                if code and any(r[1] == "NOT_RUN" for r in expected):
                    self.assertNotIn("lxc", [c["kind"] for c in calls])
                self.assertNotIn("Forge final results", result.stderr)

    def test_metadata_diagnostics_and_counts_from_real_handoffs(self):
        repository = "https://github.com/Whisparr/Whisparr"
        message = "ERROR: os_update (exit 41): dependency could not be resolved"
        warning = "OK; WARNING: fstrim failed (exit 8)"
        result, calls = self.invoke(
            "all", FORGE_TABLE_WIDTH="110",
            FORGE_TEST_HOST_APT="9",
            FORGE_TEST_LXC_APT=json.dumps({"100": 0, "111": 7, "115": 999}),
            FORGE_TEST_LXC_CODES=json.dumps({"111": 41, "115": 43}),
            FORGE_TEST_LXC_APP=json.dumps({
                "100": ["1.0+debian-2", "1.0+debian-2", repository],
                "111": ["2.0", "2.8", repository],
                "115": ["-", "-", "https://invalid.example/repository"],
            }),
            FORGE_TEST_LXC_DETAIL=json.dumps({
                "100": [quote(warning, safe=""), "-", "-"],
                "111": [quote(message + "; recovery succeeded", safe=""),
                        "os_update", "success"],
                "115": [quote("ERROR: application_update (exit 43); "
                              "recovery failed (exit 77)", safe=""),
                        "application_update", "failed:77"],
            }),
        )
        rows, table = self.assert_consistent(
            result, calls,
            [("HOST", "OK", "completed"),
             ("100", "OK", "completed"),
             ("111", "ERROR", "update_failed"),
             ("115", "ERROR", "update_failed")],
            1,
        )
        self.assertEqual([r["apt_upgraded"] for r in rows],
                         ["9", "0", "7", "999"])
        self.assertEqual(
            [(r["app_before"], r["app_after"], r["app_repository"])
             for r in rows[1:]],
            [("1.0+debian-2", "1.0+debian-2", repository),
             ("2.0", "2.8", repository), ("-", "-", "-")],
        )
        self.assertRegex(table, r"(?m)^100\s+\|\s+guest100\s+\|\s+0\s+\|\s+1\.0\+debian-2\s+\|")
        self.assertRegex(table, r"(?m)^111\s+\|\s+guest111\s+\|\s+7\s+\|\s+2\.0 → 2\.8\s+\|")
        # Full official URLs are printed once each in the compact link legend.
        self.assertEqual(table.count("Changelog: " + repository), 1)
        self.assertIn(message, table)
        self.assertIn("recovery succeeded", table)
        self.assertIn("recovery failed (exit 77)", table)
        self.assertIn(warning, table)
        self.assertEqual(rows[2]["failed_stage"], "os_update")
        self.assertEqual(rows[2]["exit_code"], "41")
        self.assertEqual(rows[3]["recovery"], "failed:77")
        self.assertEqual(rows[3]["exit_code"], "43")
        self.assertNotIn("invalid.example", table)

    def test_unknown_apt_and_versions_are_not_reported_as_zero(self):
        result, calls = self.invoke(
            "lxc", FORGE_TABLE_WIDTH="110",
            FORGE_TEST_LXC_APT=json.dumps({"100": "unknown", "111": 0, "115": 8}),
            FORGE_TEST_LXC_APP=json.dumps({
                "100": ["not-a-version", "1.3", "https://github.com/pi-hole/pi-hole"],
                "111": ["2.0", "???", "-"],
            }),
        )
        rows, table = self.assert_consistent(
            result, calls,
            [("100", "OK", "completed"),
             ("111", "OK", "completed"),
             ("115", "OK", "completed")], 0,
        )
        self.assertEqual(rows[0]["apt_upgraded"], "-")
        self.assertEqual(rows[1]["apt_upgraded"], "0")
        self.assertEqual(rows[2]["apt_upgraded"], "8")
        self.assertRegex(table, r"(?m)^100\s+\|\s+guest100\s+\|\s+—\s+\|\s+—\s+\|")
        self.assertRegex(table, r"(?m)^111\s+\|\s+guest111\s+\|\s+0\s+\|\s+—\s+\|")
        self.assertEqual(rows[0]["app_repository"], "https://github.com/pi-hole/pi-hole")

    def test_invalid_duplicate_inventory_fails_before_any_mutation(self):
        for inventory in ("100,100,111", "100,111,111"):
            with self.subTest(inventory=inventory):
                result, calls = self.invoke(
                    "all", FORGE_TEST_INVENTORY_VMIDS=inventory,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate LXC inventory VMID", result.stderr)
                self.assertNotIn("host", [c["kind"] for c in calls])
                self.assertNotIn("lxc", [c["kind"] for c in calls])
                self.assertNotIn("Forge final results", result.stdout)

    def test_rendering_exception_cannot_mask_real_update_failure(self):
        renderer = self.root / "lib/results/table.py"
        renderer.unlink()
        renderer.write_text("raise RuntimeError('deliberate renderer failure')\n",
                            encoding="utf-8")
        result, calls = self.invoke(
            "all", FORGE_TEST_LXC_CODES=json.dumps({"111": 42}),
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("final table rendering failed", result.stderr)
        self.assertNotIn("Forge final results", result.stdout)
        self.assertEqual(len(self.inventory(result)), 4)
        self.assertEqual(self.changes(calls, "lxc"), ["100", "111", "115"])
        self.assertIn("update_all=failed stage=lxc", result.stdout)

    def test_renderer_failure_does_not_mask_host_primary_exit_code(self):
        renderer = self.root / "lib/results/table.py"
        renderer.unlink()
        renderer.write_text("raise RuntimeError('deliberate renderer failure')\n",
                            encoding="utf-8")
        result, calls = self.invoke("all", FORGE_TEST_HOST_CODE="47")
        self.assertEqual(result.returncode, 47)
        self.assertIn("final table rendering failed", result.stderr)
        self.assertEqual(len(self.inventory(result)), 4)
        self.assertEqual(self.changes(calls, "lxc"), [])
        self.assertEqual(len([c for c in calls if c["kind"] == "host"]), 1)

    def test_terminal_colour_is_only_presentation(self):
        options = {
            "FORGE_TEST_LXC_CODES": '{"111":42}',
            "FORGE_TABLE_WIDTH": "110",
        }
        plain, plain_calls = self.invoke("lxc", FORGE_TABLE_COLOR="never", **options)
        forced, forced_calls = self.invoke("lxc", FORGE_TABLE_COLOR="always", **options)
        no_color, no_color_calls = self.invoke("lxc", FORGE_TABLE_COLOR="always",
                                              NO_COLOR="1", **options)
        self.assertEqual(plain.returncode, forced.returncode)
        self.assertEqual(forced.returncode, no_color.returncode)
        self.assertEqual(self.inventory(plain), self.inventory(forced))
        self.assertEqual(self.inventory(plain), self.inventory(no_color))
        self.assertEqual(plain_calls, forced_calls)
        self.assertEqual(plain_calls, no_color_calls)
        self.assertNotIn("\033[", plain.stdout)
        self.assertIn("\033[31m", forced.stdout)
        self.assertNotIn("\033[", no_color.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
