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

## Final-results inventory (F220)

Bulk runs snapshot all local LXC identities, states and selection classifications via the read-only `lib/results/inventory.sh` helper, including stopped, excluded, templates and disabled scopes. The **actual update scope** still comes exclusively from `lxc/list-targets.sh`; disagreements block mutation before updates. Once finished (including blocked preflight or failed host update), the coordinator emits one `result_target` machine-readable line per applicable host/LXC, sorted by numeric VMID. Each record stores ID, name, selected/attempted, `OK`, `ERROR`, `SKIPPED` or `NOT_RUN`, a stable reason and the original exit code on attempted failures. Skip precedence is template, stopped, excluded, disabled. A host failure marks still-eligible guests `NOT_RUN reason=host_update_failed`; preflight failure marks them `NOT_RUN reason=preflight_blocked`.

These **intermediate structured records feed F225**; they are not a second F157 notification or a finished results table. F147 human summaries and original exit codes are unchanged.

## Actual APT upgrade counts (F221)

F221 adds `apt_upgraded=<number|->` to the existing `result_target` record. The count comes from comparing installed dpkg versions at the start and **final persisted state** after any recovery, not from `apt-get` output, available-upgrade lists or download counts. Only strictly newer versions of packages installed in both snapshots count; new packages, removals, downgrades and unchanged/held packages do not. Non-mutating, skipped, blocked and unmeasurable targets use `-`, while a verified zero is `0`. Measurements also include APT changes made by supported application/custom-script stages when those are enabled.

Standalone host/LXC updates own their measurements. Bulk updates receive the per-target count through a private temporary file, add it to the **same** F220 record and delete the handoff directory on exit; stage output and original update exit codes are not captured or modified. Rollback may undo updates, so its final guest state is always authoritative. The rich table that consumes this field remains F225.
