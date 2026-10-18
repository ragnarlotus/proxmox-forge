#!/usr/bin/env python3
"""F121: unattended updates select only explicitly authorized running VMIDs."""

import unittest

from test_results import ResultAggregationTests


class ScheduledUpdateTests(unittest.TestCase):
    setUp = ResultAggregationTests.setUp
    invoke = ResultAggregationTests.invoke
    inventory = staticmethod(ResultAggregationTests.inventory)

    @staticmethod
    def called(calls, kind):
        return [call["args"][0] for call in calls if call["kind"] == kind]

    def test_no_authorized_targets_is_fail_closed_even_when_manual_scopes_enabled(self):
        result, calls = self.invoke("scheduled", FORGE_TEST_SCHEDULED_HOST="false",
                                    FORGE_TEST_SCHEDULED_LXC="")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no authorized targets", result.stderr)
        self.assertEqual(calls, [])
        self.assertNotIn("Forge final results", result.stdout)

    def test_only_one_authorized_lxc_is_updated(self):
        result, calls = self.invoke("scheduled", FORGE_TEST_SCHEDULED_LXC="111")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(calls, "lxc"), ["111"])
        self.assertEqual(self.called(calls, "space"), ["111"])
        self.assertEqual(self.called(calls, "memory"), ["111"])
        self.assertEqual(self.called(calls, "host"), [])
        rows = self.inventory(result)
        self.assertEqual(
            [(row["vmid"], row["status"], row["reason"]) for row in rows],
            [("HOST", "SKIPPED", "host_disabled"),
             ("100", "SKIPPED", "scheduled_not_authorized"),
             ("111", "OK", "completed"),
             ("115", "SKIPPED", "scheduled_not_authorized")],
        )
        self.assertEqual(result.stdout.count("Forge final results"), 1)
        self.assertIn("Overall result: SUCCESS", result.stdout)

    def test_scheduled_selection_ignores_manual_host_and_guest_policy(self):
        result, calls = self.invoke(
            "scheduled", FORGE_TEST_UPDATE_HOST="false",
            FORGE_TEST_RUNNING_LXC="false",
            FORGE_TEST_SCHEDULED_HOST="true",
            FORGE_TEST_SCHEDULED_LXC="115,100",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([c["kind"] for c in calls].count("host"), 1)
        self.assertEqual(self.called(calls, "lxc"), ["100", "115"])
        self.assertEqual(
            [(r["vmid"], r["status"]) for r in self.inventory(result)],
            [("HOST", "OK"), ("100", "OK"), ("111", "SKIPPED"), ("115", "OK")],
        )

    def test_host_only_does_not_select_manual_running_guest_scope(self):
        result, calls = self.invoke("scheduled", FORGE_TEST_SCHEDULED_HOST="true",
                                    FORGE_TEST_SCHEDULED_LXC="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len([c for c in calls if c["kind"] == "host"]), 1)
        self.assertEqual(self.called(calls, "lxc"), [])
        rows = self.inventory(result)
        self.assertEqual([r["reason"] for r in rows[1:]],
                         ["scheduled_not_authorized"] * 3)

    def test_exclude_overrides_authorization(self):
        result, calls = self.invoke("scheduled", FORGE_TEST_SCHEDULED_LXC="100,111",
                                    FORGE_TEST_EXCLUDE="guest111")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(calls, "lxc"), ["100"])
        rows = self.inventory(result)
        self.assertEqual((rows[2]["status"], rows[2]["reason"]), ("SKIPPED", "excluded"))

    def test_stopped_and_template_guests_never_start(self):
        result, calls = self.invoke(
            "scheduled", FORGE_TEST_SCHEDULED_LXC="100,111,115",
            FORGE_TEST_VMIDS="115",
            FORGE_TEST_INVENTORY_VMIDS="100,111,115",
            FORGE_TEST_STOPPED_VMIDS="100", FORGE_TEST_TEMPLATE_VMIDS="111",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.called(calls, "lxc"), ["115"])
        self.assertEqual(
            [(r["vmid"], r["reason"]) for r in self.inventory(result)],
            [("HOST", "host_disabled"), ("100", "stopped"),
             ("111", "template"), ("115", "completed")],
        )

    def test_stale_authorized_vmid_blocks_before_mutation(self):
        result, calls = self.invoke("scheduled", FORGE_TEST_SCHEDULED_HOST="true",
                                    FORGE_TEST_SCHEDULED_LXC="111,999")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("authorized scheduled LXC 999 does not exist", result.stderr)
        self.assertEqual(calls, [])

    def test_preflight_fails_before_host_or_lxc_changes(self):
        result, calls = self.invoke("scheduled", FORGE_TEST_SCHEDULED_HOST="true",
                                    FORGE_TEST_SCHEDULED_LXC="111",
                                    FORGE_TEST_LOW_SPACE_VMID="111")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.called(calls, "host"), [])
        self.assertEqual(self.called(calls, "lxc"), [])
        self.assertIn("NOT RUN", result.stdout)

    def test_failed_authorized_guest_keeps_original_result_and_continues(self):
        result, calls = self.invoke(
            "scheduled", FORGE_TEST_SCHEDULED_LXC="100,111",
            FORGE_TEST_LXC_CODES='{"100":42}',
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.called(calls, "lxc"), ["100", "111"])
        rows = self.inventory(result)
        self.assertEqual(
            [(r["vmid"], r["status"]) for r in rows],
            [("HOST", "SKIPPED"), ("100", "ERROR"), ("111", "OK"), ("115", "SKIPPED")],
        )
        self.assertIn("Failed and blocked targets (1):", result.stdout)
        self.assertIn("Overall result: PARTIAL", result.stdout)


if __name__ == "__main__":
    unittest.main()
