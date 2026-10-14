#!/usr/bin/env python3
"""Regression tests for live pmxcfs SQLite/WAL host configuration backups."""

import os
from pathlib import Path
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "lib/backup/host/snapshot-db.py"


class ClusterDatabaseBackupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forge-pmxcfs-wal-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.original = self.base / "live/var/lib/pve-cluster"
        self.original.mkdir(parents=True)
        self.db = self.original / "config.db"
        self.staging = self.base / "stage"
        self.snapshot = self.staging / "var/lib/pve-cluster/config.db"
        self.snapshot.parent.mkdir(parents=True)
        self.writer = sqlite3.connect(self.db)
        self.addCleanup(self.writer.close)
        self.assertEqual(self.writer.execute("PRAGMA journal_mode=WAL").fetchone(),
                         ("wal",))
        self.writer.execute("PRAGMA wal_autocheckpoint=0")
        self.writer.execute("CREATE TABLE example(value TEXT)")
        self.writer.execute("INSERT INTO example VALUES ('before')")
        self.writer.commit()
        self.writer.execute("INSERT INTO example VALUES ('committed-in-wal')")
        self.writer.commit()
        self.assertTrue(Path(str(self.db) + "-wal").exists())

    def run_snapshot(self, source=None, destination=None):
        return subprocess.run(
            ["python3", str(SNAPSHOT), str(source or self.db),
             str(destination or self.snapshot)],
            capture_output=True, text=True, check=False,
        )

    def test_snapshot_includes_committed_wal_without_modifying_source(self):
        outcome = self.run_snapshot()
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        with sqlite3.connect(self.snapshot) as conn:
            values = [x[0] for x in conn.execute("SELECT value FROM example ORDER BY rowid")]
            self.assertEqual(values, ["before", "committed-in-wal"])
            self.assertEqual(conn.execute("PRAGMA integrity_check").fetchone(), ("ok",))
        self.assertTrue(Path(str(self.db) + "-wal").exists())
        self.assertEqual(self.snapshot.stat().st_mode & 0o777, 0o600)

    def test_snapshot_rejects_corrupt_database_and_existing_destination(self):
        corrupt = self.base / "corrupt.db"
        corrupt.write_bytes(b"not sqlite\n")
        failed = self.run_snapshot(source=corrupt, destination=self.base / "bad-copy.db")
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("ERROR: cannot back up", failed.stderr)
        self.assertNotIn("ok", failed.stdout)

        successful = self.run_snapshot()
        self.assertEqual(successful.returncode, 0, successful.stderr)
        duplicate = self.run_snapshot()
        self.assertNotEqual(duplicate.returncode, 0)
        with sqlite3.connect(self.snapshot) as conn:
            self.assertEqual(conn.execute("PRAGMA integrity_check").fetchone(), ("ok",))

    def test_archive_contains_snapshot_only_not_live_database_or_sidecars(self):
        outcome = self.run_snapshot()
        self.assertEqual(outcome.returncode, 0, outcome.stderr)
        (self.original / "other-config").write_text("keep me", encoding="utf-8")
        archive = self.base / "host-config.tar.gz"
        command = [
            "tar", "-czf", str(archive),
            *["--exclude=" + str(self.original / name) for name in (
                "config.db", "config.db-wal", "config.db-shm",
                "config.db-journal",
            )],
            str(self.original),
            "-C", str(self.staging), "var/lib/pve-cluster/config.db",
        ]
        result = subprocess.run(command, capture_output=True, text=True,
                                check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        with tarfile.open(archive, mode="r:gz") as tar:
            names = tar.getnames()
            self.assertEqual(names.count("var/lib/pve-cluster/config.db"), 1)
            self.assertFalse(any(name.endswith(("config.db-wal",
                             "config.db-shm", "config.db-journal")) for name in names))
            self.assertFalse(any(name.endswith("/live/var/lib/pve-cluster/config.db")
                                 for name in names))
            self.assertTrue(any(name.endswith("/other-config") for name in names))
            extracted = tar.extractfile("var/lib/pve-cluster/config.db")
            self.assertIsNotNone(extracted)
            (self.base / "restored.db").write_bytes(extracted.read())
        with sqlite3.connect(self.base / "restored.db") as conn:
            self.assertEqual(
                conn.execute("SELECT value FROM example ORDER BY rowid").fetchall(),
                [("before",), ("committed-in-wal",)],
            )
            self.assertEqual(conn.execute("PRAGMA integrity_check").fetchone(), ("ok",))


if __name__ == "__main__":
    unittest.main()
