#!/usr/bin/env python3
"""Create a consistent standalone copy of a live Proxmox SQLite config.db."""

import os
from pathlib import Path
import sqlite3
import sys
from urllib.parse import quote


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: snapshot-db.py SOURCE_DB DESTINATION_DB")

    source_path = Path(sys.argv[1])
    destination_path = Path(sys.argv[2])
    if not source_path.is_file() or destination_path.exists():
        raise ValueError("source database must exist and destination must not exist")

    # Never modify the source. The SQLite backup API reads committed WAL
    # transactions and produces a consistent snapshot without stopping pmxcfs.
    source_uri = f"file:{quote(str(source_path), safe='/')}?mode=ro"
    with sqlite3.connect(source_uri, uri=True, timeout=15) as source:
        with sqlite3.connect(str(destination_path), timeout=15) as dest:
            os.chmod(destination_path, 0o600)
            source.backup(dest)
            integrity = dest.execute("PRAGMA integrity_check").fetchone()
            if integrity != ("ok",):
                raise ValueError(f"SQLite snapshot failed integrity check: {integrity!r}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, sqlite3.Error, ValueError) as exc:
        print(f"ERROR: cannot back up Proxmox cluster SQLite database: {exc}", file=sys.stderr)
        sys.exit(1)
