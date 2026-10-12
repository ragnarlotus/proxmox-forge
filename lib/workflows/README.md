# Bulk update workflow

## Bulk-update failure model

`forge update all` deliberately has asymmetric host and guest semantics. `forge lxc update all` follows the LXC stage only:

```text
freeze effective running-LXC VMID scope
        │
        ▼
check recovery compatibility of every selected LXC
   │
   ├─ conflict → abort before host or guest mutation
   │
   ▼
update host
   │
   ├─ failure → abort global run before any LXC starts
   │
   ▼
update LXCs serially
   │
   ├─ target failure → recover if possible, record failure, continue
   │
   └─ remaining targets continue
        │
        ▼
aggregate final result
```

This means `continue after guest failure` never means `convert failure into success`. The selected running LXCs are checked for root free space and available memory before any host/guest mutation; the centralized read-only recovery conflict checker then runs once for the complete scope. Individual LXC requirements repeat both resource checks immediately before mutation. The default `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true` permits backup-only recovery for snapshot-incompatible LXCs only when preflight safety requirements pass; setting it to `false` blocks those LXCs. Stopped LXCs are excluded from bulk scope.

## Final result summary

Forge prints a human-readable summary after individual host or LXC updates and after bulk runs. Bulk summaries include host status, selected/succeeded/failed LXC counts, and individual failed VMIDs with their exit codes. If the host update fails, the summary states that LXC updates did not start. Disabled scopes are distinguished from failed updates.

The readable summary is additional terminal output; existing structured `update=...` and `update_all=...` records, log records, failure aggregation and exit codes retain their previous semantics.

## Validation status

The current critical path has been manually exercised on a live Proxmox system, including:

- complete host-and-LXC bulk-update execution (previous CLI name: `update-all`);
- deliberate LXC systemd health failure detection and recovery;
- real-time carriage-return progress handling;
- sanitized persistent logging;
- terminal scrollback preservation across Community Scripts screen clears;
- host APT `autoremove` after simulation and boot-kernel validation;
- LXC APT `autoremove` simulation;
- real LXC `pct fstrim` execution;
- end-to-end explicit update of an initially stopped LXC, including temporary startup, recovery backup, OS/application update, health check, `fstrim`, and restoration to `stopped` state.

There is not yet a repeatable automated unit/integration/end-to-end test suite. That remains tracked in [`FEATURE_CHECKLIST.md`](../../FEATURE_CHECKLIST.md).


## Final notification preview (F157)

After a bulk run, Forge renders a single plain-text final notification draft: `Subject:`, `Status:`, operation, optional host status, selected/succeeded/failed LXC counts and failed VMIDs/exit codes. The status is `SUCCESS` when all attempted updates succeed, `FAILED` when none succeed and a failure occurs, or `PARTIAL` when successful and failed updates coexist (a successful host update counts as success even if every guest fails). If a bulk preflight blocks all updates, its reason is reported as `FAILED` without starting mutations. Individual host/LXC drafts are suppressed inside bulk runs to prevent duplicate email messages.

The draft is currently displayed as `Forge final notification preview (email not sent)`. No mail is sent until F153 is implemented. These drafts are separate from and do not replace the existing F147 terminal summary or change exit codes. Detailed per-target causes beyond stage/exit code remain in F159.

F159 adds the failed stage, exact log path and the last explicit `ERROR:` or `FATAL:` diagnostic from that stage (when present) to each failed target in the notification. The excerpt is evidence from the log, not an automatic root-cause judgment. Small private metadata files transfer failure details from child updates to the bulk renderer and are removed when the run ends; no updater output is buffered or repeated.
