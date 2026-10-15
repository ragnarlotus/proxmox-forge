# Logging and terminal output


Default base directory:

```text
/var/log/proxmox-forge
```

Host logs:

```text
LOG_DIR/<PVE_FQDN>/host/common.log
LOG_DIR/<PVE_FQDN>/host/error.log
```

LXC logs:

```text
LOG_DIR/<PVE_FQDN>/lxc/<VMID>/<TIMESTAMP>.log
```

General update-run logs:

```text
LOG_DIR/<PVE_FQDN>/runs/<FORGE_RUN_ID>.log
```

Each `forge host update`, `forge lxc update TARGET|all` or `forge update all`
creates one general log before update preflights or mutations. `LOG_KEEP`
retains the newest general logs independently of the per-LXC retention.

The general log includes `run_start`/`run_end` (with CLI exit code),
the structured host/LXC events, sanitized stage output, authoritative
`result_target` records and a plain-text copy of the final six-column
table/global status. It does not replace the existing target logs; it does
not duplicate stage execution or intercept the terminal (TTY colours and
progress remain unchanged). Initial log creation failures block the update;
secondary log write failures are warned about without changing the update
result. The logfile has mode 0640 inside a 0750 directory.

`LOG_KEEP` also controls retention of timestamped per-LXC logs.

F228 reads only retained general logs through `forge status [--json]` and `forge history [RUN_ID] [--json]`; it does not create a second results database. `run_end` records the actual CLI exit code; `result_global` and `result_target` remain authoritative for outcomes. The decoder maps recorded `recovery_artifact` (LXC), `backup_artifact` (host) and `reboot_status` events to attempted targets. Missing fields are unknown and inconsistent global counts are rejected. No guest commands or mutations occur during queries.

Forge records structured events with ISO timestamps, event names, fields, exit codes and durations where available. After the APT OS stage (or before an application-only update), it captures read-only F022 `held_upgrade_pending` records (package, installed and candidate versions), a pending count, and a warning **only when a newer candidate is blocked by an explicit hold**. Holds with no newer candidates are silent. Query failures are visible warnings, not a clean zero-hold result. Host `ERROR` events are mirrored to `error.log`.

## Terminal capture behaviour

Update output is streamed live rather than buffered until the command finishes.

The terminal path preserves producer formatting such as:

- ANSI colours;
- carriage-return progress redraws;
- spinner/redraw behaviour;
- normal screen repaint sequences.

Forge filters only the terminal `CSI 3 J` sequence that clears scrollback. This allows Community Scripts headers to repaint without deleting the earlier bulk-update history from the terminal's scrollback buffer.

The persistent log receives a sanitized copy: ANSI control sequences are removed and carriage-return progress is collapsed so the log contains the final visible state instead of a separate fake line for every progress percentage.

Command stdout and stderr are captured as one combined terminal/log stream, while the command's real exit code remains authoritative.
