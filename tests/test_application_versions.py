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


# Based on the actual LXC 101 (pihole) and LXC 102 (plex) launchers.
# This text is only inspected; it is never executed.
GENERATED_LAUNCHER = """#!/usr/bin/env bash
# Community-Scripts update entrypoint (generated - do not edit by hand).
# Regenerated on install and on every successful update.
export SCRIPT_SLUG="__SLUG__"
export UPDATE_SCRIPT_NAME="__SLUG__"
export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"
export COMMUNITY_SCRIPTS_CORE_URL="https://raw.githubusercontent.com/community-scripts/core/main"
export COMMUNITY_SCRIPTS_WEBSITE_URL="https://community-scripts.org"
# Pull the shared helper; it decides whether this app can still be updated. If it
# cannot be fetched, fall back to the legacy direct pull so update still works.
_cs_helper="$(curl -fsSL --connect-timeout 10 "${COMMUNITY_SCRIPTS_CORE_URL}/misc/update.sh" 2>/dev/null)"
if [[ -n "$_cs_helper" ]]; then
  bash -c "$_cs_helper"
else
  echo "Update helper unavailable - falling back to direct update."
  bash -c "$(curl -fsSL "${COMMUNITY_SCRIPTS_URL}/ct/${UPDATE_SCRIPT_NAME}.sh")"
fi
"""


def generated_launcher(slug):
    return GENERATED_LAUNCHER.replace("__SLUG__", slug)



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
            'elif kind=="cat":\n'
            '    expected="/root/."+os.environ.get("APP_TEST_MARKER_SLUG", "trek")\n'
            '    value=os.environ.get("APP_TEST_MARKER_VERSION", "")\n'
            '    if len(a)!=5 or a[4]!=expected or not value: sys.exit(91)\n'
            '    print(value)\n'
            'elif kind=="dpkg-query":\n'
            '    print(os.environ.get("APP_TEST_OUTPUT","ii \t1.0"))\n'
            'elif kind in ("caddy","/usr/local/bin/pihole","node") or '
            '(kind in ("/opt/vaultwarden/bin/vaultwarden","/usr/bin/vaultwarden")):\n'
            '    print(os.environ.get("APP_TEST_OUTPUT",""))\n'
            'else:\n'
            '    sys.exit(91)\n', encoding="utf-8",
        )
        pct.chmod(0o755)
        curl = self.bin / "curl"
        curl.write_text(
            '#!/usr/bin/env python3\n'
            'import os,sys\n'
            'from pathlib import Path\n'
            'slug=os.environ.get("APP_TEST_CURL_SLUG", "pihole")\n'
            'url="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/"+slug+".sh"\n'
            'if not sys.argv[1:] or sys.argv[-1]!=url: sys.exit(92)\n'
            'if os.environ.get("APP_TEST_CURL_CALLS"):\n'
            '    with Path(os.environ["APP_TEST_CURL_CALLS"]).open("a") as log:\n'
            '        log.write(" ".join(sys.argv[1:])+"\\n")\n'
            'if os.environ.get("APP_TEST_CURL_FAIL") or "APP_TEST_METADATA" not in os.environ:\n'
            '    sys.exit(22)\n'
            'print(os.environ["APP_TEST_METADATA"])\n',
            encoding="utf-8",
        )
        curl.chmod(0o755)
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

    def test_generated_entrypoints_from_actual_proxmox_installs(self):
        for slug in ("pihole", "plex", "immich", "caddy",
                     "vaultwarden", "docmost", "audiobookshelf"):
            with self.subTest(slug=slug):
                result = self.run_bash(
                    "forge_app_detect_slug 101 /usr/bin/update",
                    APP_TEST_LAUNCHER=generated_launcher(slug),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), slug)

    def test_generated_identity_must_be_unambiguous_and_from_official_source(self):
        valid = generated_launcher("plex")
        cases = [
            valid.replace('export UPDATE_SCRIPT_NAME="plex"',
                          'export UPDATE_SCRIPT_NAME="pihole"'),
            valid.replace('export SCRIPT_SLUG="plex"',
                          'export SCRIPT_SLUG="plex"\nexport SCRIPT_SLUG="pihole"'),
            valid.replace('export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"',
                          'export COMMUNITY_SCRIPTS_URL="https://other.example/ProxmoxVE/main"'),
            valid.replace('export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"',
                          'export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"\n'
                          'export COMMUNITY_SCRIPTS_URL="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"'),
            valid.replace('# Community-Scripts update entrypoint (generated - do not edit by hand).',
                          '# Unknown updater'),
            valid.replace('export SCRIPT_SLUG="plex"', 'export SCRIPT_SLUG="$(danger)"'),
            valid.replace('${COMMUNITY_SCRIPTS_URL}/ct/${UPDATE_SCRIPT_NAME}.sh',
                          'https://other.example/ct/${UPDATE_SCRIPT_NAME}.sh'),
            valid.replace('export UPDATE_SCRIPT_NAME="plex"', ''),
            valid.replace('export SCRIPT_SLUG="plex"', ''),
        ]
        for malformed in cases:
            with self.subTest(malformed=malformed[:140]):
                result = self.run_bash(
                    "forge_app_detect_slug 101 /usr/bin/update",
                    APP_TEST_LAUNCHER=malformed,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")

    def test_application_urls_come_from_community_scripts_metadata(self):
        cases = [
            ("caddy",
             "# Source: https://caddyserver.com/ | Github: https://github.com/caddyserver/caddy",
             "https://github.com/caddyserver/caddy"),
            ("immich",
             "# Source: https://immich.app | Github: https://github.com/immich-app/immich",
             "https://github.com/immich-app/immich"),
            ("snowshare",
             "# Source: https://github.com/TuroYT/snowshare",
             "https://github.com/TuroYT/snowshare"),
            ("trek",
             "# Source: https://github.com/liketrek/TREK",
             "https://github.com/liketrek/TREK"),
            ("pihole",
             "# Source: https://pi-hole.net/",
             "https://pi-hole.net/"),
            ("audiobookshelf",
             "# Source: https://www.audiobookshelf.org/",
             "https://www.audiobookshelf.org/"),
            ("example",
             "# Source: http://example.net/project | Github: https://github.com/org/project",
             "https://github.com/org/project"),
            ("example",
             "# Source: http://example.net/project",
             "http://example.net/project"),
            ("example",
             "# Github: https://github.com/org/project\n# Source: https://example.net",
             "https://github.com/org/project"),
            ("example",
             "# Source: https://example.org",
             "https://example.org"),
            ("example", "# License: MIT\n# Author: someone", "-"),
            ("example", "# Source: not-a-url | Github: bad-data", "-"),
            ("example",
             "# Source: https://fallback.example | Github: javascript:alert(1)",
             "https://fallback.example"),
            ("example",
             "# Source: https://fallback.example | Github: https://evil.example/a\\tb",
             "https://fallback.example"),
        ]
        calls = self.base / "curl-calls"
        for slug, metadata, expected in cases:
            with self.subTest(slug=slug, metadata=metadata):
                result = self.run_bash(
                    f'forge_app_repository "{slug}"',
                    APP_TEST_CURL_SLUG=slug,
                    APP_TEST_METADATA=(
                        '#!/usr/bin/env bash\n'
                        'source <(echo "this must never execute")\n'
                        '# Copyright\n' + metadata
                    ),
                    APP_TEST_CURL_CALLS=str(calls),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
        self.assertEqual(len(calls.read_text().splitlines()), len(cases))
        self.assertTrue(all("--proto" in line and "raw.githubusercontent.com" in line
                            for line in calls.read_text().splitlines()))

    def test_remote_metadata_failure_and_unsafe_slug_fail_closed(self):
        failed = self.run_bash("forge_app_repository pihole",
                               APP_TEST_CURL_FAIL="true")
        self.assertEqual(failed.returncode, 0, failed.stderr)
        self.assertEqual(failed.stdout.strip(), "-")
        calls = self.base / "invalid-calls"
        unsafe = self.run_bash(
            'forge_app_repository "pihole;touch /tmp/unwanted"',
            APP_TEST_CURL_CALLS=str(calls),
        )
        self.assertEqual(unsafe.returncode, 0, unsafe.stderr)
        self.assertEqual(unsafe.stdout.strip(), "-")
        self.assertFalse(calls.exists())

    def test_repository_is_fetched_only_after_confirmed_successful_change(self):
        calls = self.base / "only-on-change"
        base = dict(
            APP_TEST_LAUNCHER=generated_launcher("pihole"),
            APP_TEST_CURL_SLUG="pihole",
            APP_TEST_METADATA="# Source: https://pi-hole.net/",
            APP_TEST_CURL_CALLS=str(calls),
        )
        unchanged = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; forge_app_finalize 101 '
            '"" true; printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_REPOSITORY"',
            APP_TEST_OUTPUT="Core version is v6.4.3", **base,
        )
        self.assertEqual(unchanged.stdout.strip(), "v6.4.3|-")
        self.assertFalse(calls.exists())

        before_only = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            'printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_REPOSITORY"',
            APP_TEST_OUTPUT="Core version is v6.4.3", **base,
        )
        self.assertEqual(before_only.stdout.strip(), "v6.4.3|-")
        self.assertFalse(calls.exists())

        changed = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            'APP_TEST_OUTPUT="$APP_TEST_AFTER"; export APP_TEST_OUTPUT; '
            'forge_app_finalize 101 "" true; '
            'printf "%s|%s\n" "$FORGE_APP_AFTER" "$FORGE_APP_REPOSITORY"',
            APP_TEST_OUTPUT="Core version is v6.4.3",
            APP_TEST_AFTER="Core version is v6.5.0", **base,
        )
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertEqual(changed.stdout.strip(), "v6.5.0|https://pi-hole.net/")
        self.assertEqual(len(calls.read_text().splitlines()), 1)

        failed = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            'APP_TEST_OUTPUT="$APP_TEST_AFTER"; export APP_TEST_OUTPUT; '
            'forge_app_finalize 101; '
            'printf "%s|%s\n" "$FORGE_APP_AFTER" "$FORGE_APP_REPOSITORY"',
            APP_TEST_OUTPUT="Core version is v6.4.3",
            APP_TEST_AFTER="Core version is v6.5.0", **base,
        )
        self.assertEqual(failed.stdout.strip(), "v6.5.0|-")
        self.assertEqual(len(calls.read_text().splitlines()), 1)

    def test_supported_app_probes(self):
        for slug, output, expected in [
            ("plex", "ii \t1.43.2.11", "1.43.2.11"),
            ("audiobookshelf", "ii \t2.33.0-1", "2.33.0-1"),
            ("caddy", "v2.11.4 h1:sum", "v2.11.4"),
            ("pihole", "Core version is v6.4.3 (Latest: v6.4.3)\n"
                       "Web version is v6.6 (Latest: v6.6)\n"
                       "FTL version is v6.7.1 (Latest: v6.7.1)", "v6.4.3"),
            ("vaultwarden", "vaultwarden 1.35.0", "1.35.0"),
            ("vaultwarden", "Vaultwarden 1.37.4\nWeb-Vault Version file missing", "1.37.4"),
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
            ("vaultwarden", "Web-Vault Version file missing"),
            ("vaultwarden", "Vaultwarden not-installed\nWeb-Vault Version file missing"),
            ("vaultwarden", "Vaultwarden 1.37.4 invalid text"),
        ]:
            with self.subTest(slug=slug, output=value):
                r = self.run_bash(f"forge_app_probe 101 {slug}", APP_TEST_OUTPUT=value)
                self.assertNotEqual(r.returncode, 0)

    def test_live_pihole_and_vaultwarden_outputs_have_verified_versions(self):
        # The two actual outputs reported by CT 101 and CT 107 in October 2026.
        for slug, raw, expected in [
            (
                "pihole",
                "Core version is v6.4.3 (Latest: v6.4.3)\n"
                "Web version is v6.6 (Latest: v6.6)\n"
                "FTL version is v6.7.1 (Latest: v6.7.1)",
                "v6.4.3",
            ),
            (
                "vaultwarden",
                "Vaultwarden 1.37.4\nWeb-Vault Version file missing",
                "1.37.4",
            ),
        ]:
            with self.subTest(slug=slug):
                result = self.run_bash(
                    f'forge_app_begin 101 /usr/bin/update; '
                    'forge_app_finalize 101; '
                    'printf "%s|%s\\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
                    APP_TEST_LAUNCHER=generated_launcher(slug),
                    APP_TEST_OUTPUT=raw,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"{expected}|{expected}")

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
                    APP_TEST_LAUNCHER=generated_launcher("plex"),
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
                APP_TEST_LAUNCHER=generated_launcher("plex"),
                APP_TEST_OUTPUT=before, APP_TEST_AFTER=after,
            )
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), "-|-")

    def test_generic_community_scripts_version_marker(self):
        # No Trek-specific adapter: identity comes from /usr/bin/update,
        # installed version from Community Scripts' /root/.<slug> marker.
        for slug in ("trek", "other-project", "example7"):
            with self.subTest(slug=slug):
                r = self.run_bash(
                    'forge_app_begin 101 /usr/bin/update; '
                    'APP_TEST_MARKER_VERSION=5.1.0; export APP_TEST_MARKER_VERSION; '
                    'forge_app_finalize 101; '
                    'printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
                    APP_TEST_LAUNCHER=generated_launcher(slug),
                    APP_TEST_MARKER_SLUG=slug,
                    APP_TEST_MARKER_VERSION="4.3.4",
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), "4.3.4|5.1.0")

    def test_invalid_or_missing_release_markers_do_not_invent_versions(self):
        for marker in ("", "garbage", "1.2 2.3", "1.2\n2.3", "v"):
            with self.subTest(marker=marker):
                r = self.run_bash(
                    'forge_app_begin 101 /usr/bin/update; '
                    'forge_app_finalize 101; '
                    'printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
                    APP_TEST_LAUNCHER=generated_launcher("trek"),
                    APP_TEST_MARKER_VERSION=marker,
                )
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stdout.strip(), "-|-")

    def test_generic_successful_deployment_log_without_marker(self):
        log = self.base / "trek-update.log"
        log.write_text(
            "2026 level=INFO event=stage_start stage=application_update command=helper\n"
            "  Update available: trek 4.3.4 -> 5.1.0\n"
            "  Deployed: trek (5.1.0)\n"
            "  Updated Successfully!\n"
            "2026 level=INFO event=stage_end stage=application_update status=success exit_code=0\n",
            encoding="utf-8",
        )
        r = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            f'forge_app_finalize 101 "{log}" true; '
            'printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
            APP_TEST_LAUNCHER=generated_launcher("trek"),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "4.3.4|5.1.0")

        # Failed updater/rollback cannot use logged deployed version to claim
        # that the restored application is still on the new release.
        failed = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            f'forge_app_finalize 101 "{log}"; '
            'printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
            APP_TEST_LAUNCHER=generated_launcher("trek"),
        )
        self.assertEqual(failed.stdout.strip(), "-|-")
        log.write_text(log.read_text().replace("status=success", "status=failed"))
        unsuccessful = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            f'forge_app_finalize 101 "{log}" true; '
            'printf "%s|%s\n" "$FORGE_APP_BEFORE" "$FORGE_APP_AFTER"',
            APP_TEST_LAUNCHER=generated_launcher("trek"),
        )
        self.assertEqual(unsuccessful.stdout.strip(), "-|-")

    def test_bulk_handoff_uses_shared_results_not_console_duplication(self):
        handoff = self.base / "app-record"
        r = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; '
            'APP_TEST_OUTPUT="$APP_TEST_AFTER"; export APP_TEST_OUTPUT; '
            'forge_app_finalize 101',
            APP_TEST_LAUNCHER=generated_launcher("plex"),
            APP_TEST_OUTPUT="ii \t1.0",
            APP_TEST_AFTER="ii \t2.0",
            FORGE_RESULTS_AGGREGATE="bulk",
            FORGE_APP_RESULT_FILE=str(handoff),
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(handoff.read_text(encoding="utf-8"), "1.0\t2.0\t-\n")
        self.assertEqual(r.stdout, "")

    def test_bulk_handoff_omits_repository_for_noop(self):
        handoff = self.base / "repo-record"
        result = self.run_bash(
            'forge_app_begin 101 /usr/bin/update; forge_app_finalize 101',
            APP_TEST_LAUNCHER=generated_launcher("pihole"),
            APP_TEST_OUTPUT="Core version is v6.4.3",
            FORGE_RESULTS_AGGREGATE="bulk",
            FORGE_APP_RESULT_FILE=str(handoff),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            handoff.read_text(encoding="utf-8"),
            "v6.4.3\tv6.4.3\t-\n",
        )
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
