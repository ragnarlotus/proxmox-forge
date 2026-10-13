#!/usr/bin/env python3
"""F222: read-only Community Scripts launcher identification and installed-version probes."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "lib/results/application.sh"
SCRIPT_URL = "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/{}.sh"
LEGACY_URL = "https://github.com/tteck/Proxmox/raw/main/ct/{}.sh"


class ApplicationVersionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="forge-app-version-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        pct = self.bin / "pct"
        pct.write_text(
            '#!/usr/bin/env python3\n'
            'import os,sys\n'
            'a=sys.argv[1:]\n'
            'if len(a)<4 or a[:3]!=["exec","101","--"]:\n'
            '    sys.exit(90)\n'
            'kind=a[3]\n'
            'if kind=="head":\n'
            '    print(os.environ.get("APP_TEST_LAUNCHER",""))\n'
            'elif kind=="dpkg-query":\n'
            '    print(os.environ.get("APP_TEST_OUTPUT","ii \t1.0"))\n'
            'elif kind in ("caddy","pihole","node") or '
            '(kind in ("/opt/vaultwarden/bin/vaultwarden","/usr/bin/vaultwarden")):\n'
            '    print(os.environ.get("APP_TEST_OUTPUT",""))\n'
            'else:\n'
            '    sys.exit(91)\n', encoding="utf-8",
        )
        pct.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}"}

    def run_bash(self, body, **extra):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; ' + body, "_", str(HELPER)],
            env={**self.env, **extra},
            capture_output=True, text=True, check=False,
        )

    def test_identity_requires_proven_community_scripts_launcher(self):
        for url in [SCRIPT_URL.format("plex"), LEGACY_URL.format("plex"),
                    "https://raw.githubusercontent.com/community-scripts/ProxmoxVE/refs/heads/main/ct/plex.sh"]:
            with self.subTest(url=url):
                r = self.run_bash("forge_app_detect_slug 101 /usr/bin/update", APP_TEST_LAUNCHER=f'bash -c "$(curl -fsSL {url})"')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), "plex")
        for launcher in ["https://example.com/ct/plex.sh",
                         "https://raw.githubusercontent.com/other/ProxmoxVE/main/ct/plex.sh",
                         SCRIPT_URL.format("plex") + "\n" + SCRIPT_URL.format("caddy"),
                         ""]:
            with self.subTest(launcher=launcher):
                r = self.run_bash("forge_app_detect_slug 101 /usr/bin/update",
                                  APP_TEST_LAUNCHER=launcher)
                self.assertNotEqual(r.returncode, 0)
        self.assertNotEqual(
            self.run_bash("forge_app_detect_slug 101 none",
                          APP_TEST_LAUNCHER=SCRIPT_URL.format("plex")).returncode, 0
        )

    def test_supported_app_probes(self):
        for slug, output, expected in [
            ("plex", "ii \t1.43.2.11", "1.43.2.11"),
            ("audiobookshelf", "ii \t2.33.0-1", "2.33.0-1"),
            ("caddy", "v2.11.4 h1:sum", "v2.11.4"),
            ("pihole", "Core version is v6.2\nWeb version is v6.3", "v6.2"),
            ("vaultwarden", "vaultwarden 1.35.0", "1.35.0"),
            ("docmost", "0.26.2", "0.26.2"),
            ("immich", "v3.3.0", "v3.3.0"),
        ]:
            with self.subTest(slug=slug):
                r = self.run_bash(f"forge_app_probe 101 {slug}",
                                  APP_TEST_OUTPUT=output)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), expected)

    def test_unknown_or_unparseable_probes_do_not_invent_versions(self):
        for slug, value in [
            ("otherapp", "1.2.3"), ("plex", "rc \t2.0"),
            ("plex", "ii \t"), ("caddy", "caddy unknown"),
            ("vaultwarden", "noise"), ("immich", "not a version"),
            ("pihole", "FTL version is v6.2"),
        ]:
            with self.subTest(slug=slug, output=value):
                r = self.run_bash(f"forge_app_probe 101 {slug}", APP_TEST_OUTPUT=value)
                self.assertNotEqual(r.returncode, 0)

    def test_before_after_updated_unchanged_and_rollback(self):
        for before, after in [("ii \t2.2.0", "ii \t2.2.1"),
                              ("ii \t2.2.0", "ii \t2.2.0"),
                              ("ii \t2.2.0", "ii \t2.2.0")]:
            with self.subTest(before=before, after=after):
                r = self.run_bash(
                    'forge_app_begin 101 /usr/bin/update; '
                    'APP_TEST_OUTPUT="$APP_TEST_AFTER"; export APP_TEST_OUTPUT; '
                    'forge_app_finalize 101; '
                    'printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
                    APP_TEST_LAUNCHER=SCRIPT_URL.format("plex"),
                    APP_TEST_OUTPUT=before, APP_TEST_AFTER=after,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(),
                                 f'{before.split(chr(9))[1]}|{after.split(chr(9))[1]}')

    def test_unavailable_after_or_before_is_unknown(self):
        for before, after in [("ii \t1.2", "rc \t2.0"),
                              ("rc \t1.2", "ii \t2.0")]:
            r = self.run_bash(
                'forge_app_begin 101 /usr/bin/update; '
                'APP_TEST_OUTPUT="$APP_TEST_AFTER"; export APP_TEST_OUTPUT; '
                'forge_app_finalize 101; printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
                APP_TEST_LAUNCHER=SCRIPT_URL.format("plex"),
                APP_TEST_OUTPUT=before, APP_TEST_AFTER=after,
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), "-|-")

    def test_bulk_handoff_uses_shared_results_not_console_duplication(self):
        handoff = self.base / "app-record"
        r = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            'APP_TEST_OUTPUT="$APP_TEST_AFTER"; export APP_TEST_OUTPUT; '
            'forge_app_finalize 101',
            APP_TEST_LAUNCHER=SCRIPT_URL.format("plex"),
            APP_TEST_OUTPUT="ii \t1.0",
            APP_TEST_AFTER="ii \t2.0",
            FORGE_RESULTS_AGGREGATE="bulk",
            FORGE_APP_RESULT_FILE=str(handoff),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(handoff.read_text(encoding="utf-8"), "1.0\t2.0\n")
        self.assertEqual(r.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
