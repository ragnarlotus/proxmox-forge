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

`LOG_KEEP` controls retention of timestamped per-LXC logs.

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
