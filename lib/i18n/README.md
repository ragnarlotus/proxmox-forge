# Forge presentation languages (F246)

`LANGUAGE=en` is the default. Set `LANGUAGE=es` in the Git-ignored
`/opt/proxmox-forge/forge.conf` to display Forge's human-facing presentation
in Spanish. Only `en` and `es` are accepted by the configuration validator.

```bash
LANGUAGE=es
```

Forge's **own** help, interactive progress dashboard, final result headings,
readable status/history views, total-run duration, interactive self-update
question and email notification presentation use the configured language.
The validated value is propagated to subprocesses (including persistent
manual updates); systemd-scheduled runs read the same local configuration.

The human-facing messages are centralized in two UTF-8 JSON catalogues:
`lib/i18n/en.json` (canonical source) and `lib/i18n/es.json`.
`translate.py` provides reusable named placeholders and an English fallback
for missing entries. A new language needs a catalogue plus an explicit update
to the supported-code validator and its tests; it must never be silently
accepted merely because a file exists.

**Intentionally not translated:** structured event names and field keys,
`result_target` / `result_global` records, result status identifiers
(`SUCCESS`, `FAILED`, `PARTIAL`, `OK`, etc.), `duration_seconds`,
JSON keys, full technical run/target logs, exact command names and paths, and
diagnostic output from APT, Proxmox or application updaters. This protects
machine consumers and preserves the exact evidence used in troubleshooting.
`FORGE_OUTPUT_MODE=full` continues to show the full technical stream,
independent of `LANGUAGE`.

For F225 tables, the *terminal* presentation and email body are localized,
but the archived run-log table remains in canonical English. Readable
`forge status` / `forge history` use the selected language without changing
their JSON responses or their interpretation of earlier logs.

The default English locale does not depend on the host's system locale,
`LANG`, `LC_ALL` or operating-system translations. Automated tests cover
the language validator, catalogue parity, both presentations and stable
machine-readable outputs.
