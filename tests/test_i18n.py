#!/usr/bin/env python3
"""F246: bilingual display tests without changing machine-readable results."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
I18N = ROOT / "lib/i18n"
TABLE = ROOT / "lib/results/table.py"
HISTORY = ROOT / "lib/results/history.py"
PROGRESS = ROOT / "lib/ui/progress.py"

sys.path.insert(0, str(I18N))
from translate import load, tr  # noqa: E402


class TranslationTests(unittest.TestCase):
    def run_cmd(self, script, *args, language=None, data=None, extra=None):
        env = {**os.environ, **(extra or {})}
        env.pop("FORGE_LANGUAGE", None)
        if language is not None:
            env["FORGE_LANGUAGE"] = language
        return subprocess.run(
            ["python3", str(script), *args],
            input=data, text=True, capture_output=True, check=False, env=env,
        )

    def test_catalogue_keys_and_format_placeholders_match(self):
        en, es = load("en"), load("es")
        self.assertEqual(set(en), set(es))
        for key in en:
            self.assertTrue(en[key].strip(), key)
            self.assertTrue(es[key].strip(), key)

    def test_default_english_spanish_and_fallback(self):
        self.assertEqual(tr("progress.title", lang="en"), "Forge — System update")
        self.assertEqual(tr("progress.title", lang="es"), "Forge — Actualización del sistema")
        self.assertEqual(tr("progress.title", lang="fr"), "Forge — System update")
        self.assertEqual(tr("progress.completed", lang="es",
                            done=2, total=5, percentage=40), "2/5 completados · 40%")

    def test_bilingual_help_keeps_identical_command_syntax(self):
        en = self.run_cmd(I18N / "help.py")
        es = self.run_cmd(I18N / "help.py", language="es")
        self.assertEqual((en.returncode, es.returncode), (0, 0), (en.stderr, es.stderr))
        self.assertIn("Usage:", en.stdout)
        self.assertIn("Uso:", es.stdout)
        for command in ("forge", "validate-config", "update self-update [BRANCH]",
                        "lxc update TARGET", "history [RUN_ID] [--json]"):
            self.assertIn(command, en.stdout)
            self.assertIn(command, es.stdout)

    def test_progress_english_is_default_and_spanish_is_opt_in(self):
        events = (
            "update_all=start mode=lxc update_host=false lxc_targets=1\n"
            "update_all_target=start vmid=100\n"
            "type=lxc vmid=100 name=wireguard state=running\n"
            "stage=start name=backup\n"
            "update_all_target=success vmid=100 exit_code=0\n"
            "result_global status=SUCCESS\n"
        )
        en = self.run_cmd(PROGRESS, "bulk", "all", data=events)
        es = self.run_cmd(PROGRESS, "bulk", "all", language="es", data=events)
        self.assertEqual((en.returncode, es.returncode), (0, 0), (en.stderr, es.stderr))
        self.assertIn("Checking requirements", en.stdout)
        self.assertIn("Comprobando requisitos", es.stdout)
        self.assertIn("Forge: result SUCCESS", en.stdout)
        self.assertIn("Forge: resultado SUCCESS", es.stdout)

    def test_spanish_table_keeps_english_run_log_and_structured_fields(self):
        row = (
            "result_target type=lxc vmid=101 name=pihole selected=true "
            "attempted=true status=OK reason=completed apt_upgraded=2 "
            "app_before=1.0 app_after=1.1 app_repository=- failed_stage=- "
            "recovery=- result_detail=OK\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            logfile = Path(tmp) / "run.log"
            logfile.touch()
            result = self.run_cmd(TABLE, language="es", data=row,
                                  extra={"FORGE_RUN_LOG": str(logfile),
                                         "FORGE_TABLE_COLOR": "never"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("Resultados finales de Forge", result.stdout)
            self.assertIn("Resultado global: SUCCESS", result.stdout)
            self.assertIn("result_global status=SUCCESS", result.stdout)
            logged = logfile.read_text()
            self.assertIn("Forge final results", logged)
            self.assertIn("Overall result: SUCCESS", logged)
            self.assertIn("result_global status=SUCCESS", logged)
            self.assertNotIn("Resultados finales", logged)

    def test_history_json_not_localized(self):
        with tempfile.TemporaryDirectory() as tmp:
            en = self.run_cmd(HISTORY, "status", tmp, "bv.deulos.com",
                              "--json", language="en")
            es = self.run_cmd(HISTORY, "status", tmp, "bv.deulos.com",
                              "--json", language="es")
            self.assertEqual((en.returncode, es.returncode), (0, 0), (en.stderr, es.stderr))
            self.assertEqual(json.loads(en.stdout), json.loads(es.stdout))
            self.assertIsNone(json.loads(es.stdout))
            view = self.run_cmd(HISTORY, "status", tmp, "bv.deulos.com",
                                language="es")
            self.assertIn("No se encontraron ejecuciones", view.stdout)


if __name__ == "__main__":
    unittest.main()
