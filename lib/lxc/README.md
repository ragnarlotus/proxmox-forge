# LXC update workflow


For one explicitly selected LXC, the current workflow is:

```text
validate configuration and resolve exact target/current state
→ if stopped, start temporarily
→ if Forge started it, wait for pct exec readiness (bounded to 30 seconds)
→ read-only requirements
→ same-run vzdump recovery backup according to the configured Proxmox job
→ optional temporary update CPU/RAM limits
→ OS/package update
→ application update
→ target-specific custom scripts
→ generic health check
→ optional health.d/<VMID>/*.sh functional checks
→ restore original CPU/RAM limits
→ pct fstrim
→ inspect /run/reboot-required inside the running LXC
→ if originally stopped, stop again
→ success
```

`UPDATE_RUNNING_LXC` and `EXCLUDE` apply only to automatic target discovery for `forge lxc list-targets` and both bulk update commands. `EXCLUDE` accepts comma-separated, case-sensitive exact VMIDs or hostnames, filters before preflights and mutation, and never blocks `forge lxc update TARGET`.

`lib/config/conflicts.sh` checks Proxmox backup-job policy and snapshot compatibility for the selected LXCs before mutation. Bulk updates check every selected running LXC before the host update; `forge validate-config` checks the automatic running LXC scope. Stopped LXCs are included only when explicitly selected. Conflicts stop the entire operation before any changes.

Forge does not use the LXC snapshot-capability API or create persistent `Update_*` snapshots. Recovery uses the exact same-run `vzdump` archive and guards against pre-existing snapshots that a forced restore could destroy. External bind-mounted data is outside the managed backup/rollback boundary. See [LXC recovery policy](../backup/README.md#lxc-recovery-policy).

F094 reports `reboot_required=yes|no|unknown` after successful updates by checking the Debian `/run/reboot-required` marker inside the guest before restoring its original stopped state. Forge never restarts a guest automatically. The guest shares the Proxmox host kernel, so restarting a container cannot activate a new host kernel. A missing marker is not proof that no restart could ever be useful. Failed detection is a nonfatal warning.

LXC requirements checks always run before backup creation or mutation. A failure stops the LXC update.

When any mutating LXC stage is enabled, `CREATE_BACKUP_BEFORE_LXC_UPDATE=true` is mandatory. Forge creates a same-run `vzdump` recovery archive and uses `pct restore --force` for eligible failures only when `ROLLBACK_ON_FAILURE=true` and no existing persistent snapshots would be destroyed. The restore helper rechecks this safety condition before restoration. Forge never deletes old snapshots or calls `pct rollback`. Backup storage/mode/compression/retention follow the applicable Proxmox job; see [Backup and recovery](../backup/README.md).

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

F220: completed individual LXC runs emit one structured `result_target` record with target and authoritative result. Bulk updates suppress nested guest records; the coordinator emits the consolidated records instead.

F221: pre/post read-only dpkg comparison adds `apt_upgraded=N|-` to the final result. If rollback restores the previous packages, the count becomes `0`. The final guest snapshot precedes returning an explicitly updated stopped LXC to its original stopped state. Application/custom-script APT upgrades are included where measurable.

F222: a read-only version probe detects Community Scripts identity from the installed `/usr/bin/update` launcher (without executing it). It first uses supported installed-package/binary probes; for other slugs it reads the standard `/root/.<slug>` installed-release marker used by Community Scripts' `check_for_gh_release`, when present and valid. If neither source exists, a successful updater can provide a version delta only when its captured `application_update` stage explicitly confirms old/new and the exact deployed version (such as Trek). Failed updates/rollback never infer versions from logs; only the final guest state is probed. The final `result_target` contains `app_before` and `app_after` (`-` if unknown). No new network requests or update executions are made.

F223: `app_repository` on the final LXC `result_target` record is the independently verified official source-code repository (or `-`). It derives from the already-identified Community Scripts slug even when the installed version cannot be measured; the repository is not the installation script URL. This informational field never invokes an updater or performs a network query.

F224: each individual LXC emits a human-actionable, percent-escaped `result_detail` alongside `failed_stage` and `recovery` in its final authoritative `result_target`. The detail preserves the primary stage and exit code, optionally an explicit sanitized error from that same stage, secondary recovery outcome and actual nonfatal warnings. When nested in bulk, it is transferred through a private temporary file and printed only by the bulk coordinator. It does not alter update, rollback or exit semantics.
