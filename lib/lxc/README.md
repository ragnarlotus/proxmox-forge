# LXC update workflow


For one explicitly selected LXC, the current workflow is:

```text
validate configuration and resolve exact target/current state
→ if stopped, start temporarily
→ if Forge started it, wait for pct exec readiness (bounded to 30 seconds)
→ read-only requirements
→ recovery backup according to the configured Proxmox job
→ persistent Update_* snapshot, or preflight-authorized backup-only recovery
→ OS/package update
→ application update
→ target-specific custom scripts
→ generic health check
→ optional health.d/<VMID>/*.sh functional checks
→ pct fstrim
→ inspect /run/reboot-required inside the running LXC
→ if originally stopped, stop again
→ success
```

`UPDATE_RUNNING_LXC` and `EXCLUDE` apply only to automatic target discovery for `forge lxc list-targets` and both bulk update commands. `EXCLUDE` accepts comma-separated, case-sensitive exact VMIDs or hostnames, filters before preflights and mutation, and never blocks `forge lxc update TARGET`.

`lib/config/conflicts.sh` checks Proxmox backup-job policy and snapshot compatibility for the selected LXCs before mutation. Bulk updates check every selected running LXC before the host update; `forge validate-config` checks the automatic running LXC scope. Stopped LXCs are included only when explicitly selected. Conflicts stop the entire operation before any changes.

Forge uses Proxmox's `hasFeature` response for `snapshot`, not a homegrown mount-point count. In the verified host configuration, the bind-mount `mp0` entries on LXCs 111, 113 and 117 return `hasFeature=0`; lower-level `lxc.mount.entry` binds on other LXCs can coexist with `hasFeature=1`. See [Snapshot eligibility, mount points and external data](../backup/README.md#snapshot-eligibility-mount-points-and-external-data) for recovery implications.

F094 reports `reboot_required=yes|no|unknown` after successful updates by checking the Debian `/run/reboot-required` marker inside the guest before restoring its original stopped state. Forge never restarts a guest automatically. The guest shares the Proxmox host kernel, so restarting a container cannot activate a new host kernel. A missing marker is not proof that no restart could ever be useful. Failed detection is a nonfatal warning.

LXC requirements checks always run before backup creation or mutation. A failure stops the LXC update.

The recovery backup is created whenever at least one mutating LXC stage is enabled and `CREATE_BACKUP_BEFORE_LXC_UPDATE=true`. Before mutation, Forge also creates a persistent Proxmox `Update_*` snapshot of the LXC. It reads `keep-last` from the single applicable enabled Proxmox backup job, prunes only the oldest `Update_*` snapshots **before** creating a new one, and leaves manually named snapshots untouched. Successful updates retain the new snapshot; failures roll back to that same-run snapshot using `pct rollback`. If no safe snapshot/retention plan is possible, mutation does not begin. With `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true`, a selected LXC that cannot create persistent snapshots instead retains the newly created `vzdump` backup as its recovery point, skipping snapshot creation. An automatic `pct restore --force` is permitted only when no persistent snapshots exist; the restore helper checks again immediately before any destructive step.

## Explicitly held APT packages (F022)

After the LXC APT update stage, Forge queries `apt-mark showhold` inside the guest, checks installed versus APT candidate versions with `apt-cache policy` and `dpkg --compare-versions`, and warns **only** when a held package has a newer candidate. Successful `apt-get update` refreshes the candidate data. If the APT stage fails, results are diagnostic context (the package lists might be stale); Forge retains the original update failure and rollback policy. If OS updates are disabled but an application updater is enabled, Forge checks against the current cached APT lists before the application stage. No additional hold check runs when neither OS nor application updates are enabled.

This also works for explicitly selected stopped LXCs during their temporary running state. It never removes holds or modifies update selection. The existence of a held package with a pending upgrade **does not establish that it caused a Community Scripts application updater failure**; the updater's own output remains authoritative. Holds without newer candidates are silent. This does not identify all packages kept back by dependency resolution.

## Package-manager update strategies

Forge currently supports APT-based LXCs only.

| Package manager | Update sequence |
| --- | --- |
| APT | `apt-get update` → `apt-get dist-upgrade` → `apt-get autoremove` |

APT runs non-interactively and preserves existing local configuration files when package defaults differ.

A non-APT LXC is rejected by requirements before the update begins.

## Community Scripts application update

For a running LXC, Forge detects an executable `/usr/bin/update`. When present and application updates are enabled, it runs:

```text
env PHS_SILENT=1 /usr/bin/update
```

through `pct exec` with standard input detached.

A non-zero application-updater exit code is authoritative: the target fails and same-run recovery is attempted when enabled and available.

## Custom scripts

Target-specific extensions live under:

```text
scripts.d/<VMID>/*.sh
```

When `RUN_CUSTOM_SCRIPTS=true`, the LXC update workflow checks for eligible scripts before planning the recovery backup. The custom-script executor then selects and runs the scripts at the custom-script stage.

Only regular files ending exactly in `.sh` are executed, in lexical order. Each script is streamed into the target container and run with Bash.

A non-zero custom-script result fails the target and participates in the same recovery semantics as the normal update stages.

The actual target-specific scripts are local data and are intentionally not versioned by this repository.

## Health check

The current generic post-update LXC health check verifies that:

- the LXC is still in `running` state;
- `pct exec` succeeds;
- when systemd is active inside the LXC, there are no failed systemd service units.

A mandatory health failure is an update failure and can trigger rollback when configured. After rollback and guest restart, Forge waits up to 30 seconds for `pct exec` readiness and reuses the same `health.sh` check before declaring recovery successful. A failed recovery check is reported separately; the original update failure remains authoritative.

## Functional health checks (F101)

Forge always performs its existing generic checks first. When `HEALTH_CHECK=true` (default), it then runs ordinary regular `.sh` files from `HEALTH_SCRIPTS_DIR/<VMID>/` inside that LXC in lexicographical order, using `pct exec VMID -- bash -s --` with each script streamed from the host. The directory defaults to `/opt/proxmox-forge/health.d` and is optional per VMID; with no checks, the existing generic behavior is preserved. `HEALTH_CHECK=false` skips the post-update health stage entirely.

The first nonzero exit code or unreadable check fails the `health` stage and participates in the existing same-run rollback policy. Checks are rerun through the same `health.sh` during post-rollback verification; a failed recovery check cannot convert the failed update into success. For an explicitly updated stopped LXC, checks run while the guest is temporarily started. This feature does not restart containers automatically.

Scripts should **only inspect application functionality**, never mutate files, databases, processes, or services. Forge cannot enforce that policy on arbitrary shell code. Tests should be repeatable, bounded (for HTTP requests, use a timeout) and reliably return nonzero when the check fails. See [health.d](../../health.d/README.md).

## Post-update filesystem trim

After an otherwise successful LXC mutation and health check, Forge runs:

```text
pct fstrim <VMID>
```

This is storage maintenance, not backup pruning. It returns filesystem blocks that are no longer in use to the underlying storage where supported.

A `fstrim` failure is logged and reported as a **warning**. Forge deliberately does not restore an otherwise healthy guest merely because trim failed.
