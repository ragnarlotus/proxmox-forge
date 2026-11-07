#!/usr/bin/env python3
"""F247: explicit multi-LXC runs reuse the real coordinator and reporting.

The fixture from test_results mocks all mutating Proxmox/update helpers.
"""
import json
import os
import subprocess
import unittest

from test_results import ResultAggregationTests


class ExplicitMultiLxcTests(unittest.TestCase):
    setUp = ResultAggregationTests.setUp
    inventory = staticmethod(ResultAggregationTests.inventory)

    def invoke_selected(self, ids, **overrides):
        self.calls_file.unlink(missing_ok=True)
        env = {**self.env, **{key: str(value) for key, value in overrides.items()}}
        result = subprocess.run(
            ["bash", str(self.root / "lib/workflows/update-all.sh"), "selected", *ids],
            cwd=self.root, env=env, capture_output=True, text=True, check=False,
        )
        calls = ([json.loads(line) for line in self.calls_file.read_text().splitlines()]
                 if self.calls_file.exists() else [])
        return result, calls

    @staticmethod
    def calls_of(calls, kind):
        return [call["args"] for call in calls if call["kind"] == kind]

    def test_explicit_order_and_unselected_lxc_skipped(self):
        result, calls = self.invoke_selected(["115", "100"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls_of(calls, "list"), [])
        self.assertEqual(self.calls_of(calls, "host"), [])
        self.assertEqual(self.calls_of(calls, "preflight"), [["115", "100"]])
        self.assertEqual(self.calls_of(calls, "space"), [["115", "1024"], ["100", "1024"]])
        self.assertEqual(self.calls_of(calls, "memory"), [["115", "128"], ["100", "128"]])
        self.assertEqual(self.calls_of(calls, "lxc"),
                         [["115", "explicit"], ["100", "explicit"]])
        rows = {row["vmid"]: row for row in self.inventory(result)}
        self.assertEqual([row["status"] for row in rows.values()],
                         ["OK", "SKIPPED", "OK"])
        self.assertEqual(rows["111"]["reason"], "not_selected")
        self.assertEqual(rows["111"]["selected"], "false")
        self.assertIn("result_global status=SUCCESS", result.stdout)
        self.assertEqual(result.stdout.count("Forge final results"), 1)

    def test_failure_does_not_prevent_subsequent_selected_update(self):
        result, calls = self.invoke_selected(
            ["115", "100"], FORGE_TEST_LXC_CODES='{"115": 17}',
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(self.calls_of(calls, "lxc"),
                         [["115", "explicit"], ["100", "explicit"]])
        rows = {row["vmid"]: row for row in self.inventory(result)}
        self.assertEqual(rows["115"]["status"], "ERROR")
        self.assertEqual(rows["115"]["exit_code"], "17")
        self.assertEqual(rows["100"]["status"], "OK")
        self.assertIn("result_global status=PARTIAL", result.stdout)

    def test_stopped_selected_guest_is_not_probed_before_start(self):
        result, calls = self.invoke_selected(
            ["111", "100"], FORGE_TEST_STOPPED_VMIDS="111",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls_of(calls, "space"), [["100", "1024"]])
        self.assertEqual(self.calls_of(calls, "memory"), [["100", "128"]])
        self.assertEqual(self.calls_of(calls, "preflight"), [["111", "100"]])
        self.assertEqual(self.calls_of(calls, "lxc"),
                         [["111", "explicit"], ["100", "explicit"]])
        rows = {row["vmid"]: row for row in self.inventory(result)}
        self.assertEqual(rows["111"]["status"], "OK")
        self.assertEqual(rows["115"]["reason"], "not_selected")

    def test_selection_ignores_automatic_exclusions_and_disabled_scope(self):
        result, calls = self.invoke_selected(
            ["111", "100"], FORGE_TEST_RUNNING_LXC="false",
            FORGE_TEST_EXCLUDE="100,111", FORGE_TEST_EXPLICIT_INVENTORY="true",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls_of(calls, "lxc"),
                         [["111", "explicit"], ["100", "explicit"]])
        rows = {row["vmid"]: row for row in self.inventory(result)}
        self.assertEqual(rows["115"]["reason"], "not_selected")

    def test_preflight_conflict_blocks_every_selected_guest(self):
        result, calls = self.invoke_selected(
            ["115", "100"], FORGE_TEST_CONFLICT="true",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls_of(calls, "lxc"), [])
        rows = {row["vmid"]: row for row in self.inventory(result)}
        self.assertEqual(rows["100"]["status"], "NOT_RUN")
        self.assertEqual(rows["115"]["status"], "NOT_RUN")
        self.assertEqual(rows["111"]["status"], "SKIPPED")
        self.assertIn("result_global status=FAILED", result.stdout)

    def test_invalid_or_duplicate_scope_never_updates(self):
        cases = (
            (["100", "100"], {}, "duplicate"),
            (["100", "999"], {}, "does not exist"),
            (["100", "111"], {"FORGE_TEST_TEMPLATE_VMIDS": "111"}, "template"),
            (["100", "bad"], {}, "invalid explicit"),
            (["100"], {}, "at least two"),
        )
        for ids, override, message in cases:
            with self.subTest(ids=ids, override=override):
                result, calls = self.invoke_selected(ids, **override)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.calls_of(calls, "lxc"), [])
                self.assertEqual(self.calls_of(calls, "preflight"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
