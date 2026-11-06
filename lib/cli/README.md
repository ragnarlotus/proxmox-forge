# Forge CLI


```text
forge validate-config
forge show-config
forge status [--json]
forge history [RUN_ID] [--json]
forge host update
forge lxc list-targets
forge lxc update TARGET
forge lxc update all
forge update all
forge update scheduled
forge update self-update [BRANCH]
forge help
```

`TARGET` may be either:

- an exact numeric Proxmox VMID; or
- an exact LXC hostname.

Partial, prefix and fuzzy matching are deliberately forbidden. An unknown target fails, and an ambiguous exact hostname also fails.

## `forge validate-config`

Loads `forge.conf.default`, then optional local `forge.conf`, validates the merged result, and checks backup-policy and persistent-snapshot compatibility for running LXCs selected by `UPDATE_RUNNING_LXC`. It reports all detected conflicts and performs no updates. When `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true`, compatible backup-only recovery is accepted, and the selected VMIDs are reported.

## `forge show-config`

Loads and validates `forge.conf.default` and optional `forge.conf`, printing the effective values in stable key order. The end of each line indicates `source=default` or `source=override` (even when an override matches the default). Values use Bash-safe quoting and sensitive-looking keys are redacted. This read-only command does not query LXC state or run the snapshot/backup recovery-policy preflight.

## Notification policies (F237)

`EMAIL_NOTIFICATIONS=false` by default disables all mail. With mail enabled,
`NOTIFY_MANUAL=errors` (default) sends one final root-mail notification only
for `FAILED` or `PARTIAL` manual host/LXC/bulk updates, while
`NOTIFY_SCHEDULED=all` (default) sends a final mail for every completed
authorized `forge update scheduled`, including `SUCCESS`. Either policy can
be set independently to `none`, `errors` or `all`. Subjects identify
`[MANUAL]` or `[SCHEDULED]` and include the global result. Mail is sent
through existing Proxmox system-mail routing, using the same F225 final
records, never individual per-target messages or Forge-managed SMTP.
`NOTIFY_ONLY_ERRORS` has been replaced and is no longer a valid config key.

## `forge status` and `forge history`

Read-only access to existing general run logs under `LOG_DIR/<PVE_FQDN>/runs/`. `forge status` displays the newest retained run; `forge history` lists retained runs newest first; `forge history RUN_ID` displays one run. Append `--json` for machine-readable output.

Only authoritative `result_target`, `result_global`, `run_start`/`run_end`, `recovery_artifact`/`backup_artifact` and `reboot_status` records are used. Results, actual APT upgrade counts, application versions, failed stage/recovery, reboot indicator and exact backup reference are reported only when present. Missing or interrupted run data are unknown/incomplete; a backup reference is **not** proof of archive integrity. `LOG_KEEP` (8 by default) limits history. Queries do not inspect/update packages, contact guests or create logs. The existing global CLI lock still applies, so another simultaneous Forge execution blocks queries until F131 introduces independent jobs.

## Elapsed time reporting (F146)

Each completed update prints the total measured execution duration in a human-readable format (for example, `33 m 16 s` or `1 h 2 m 3 s`).
The run log records `duration_seconds` on `run_end`. Existing `stage_end`
and `target_update_end` records already contain measured stage and host/LXC
durations; these are now available through `forge status [--json]` and
`forge history [RUN_ID] [--json]`.

JSON exposes `duration_seconds` on the run and each attempted target, plus
each completed entry in `targets[].stages` (`name`, `status`,
`duration_seconds`). Human output shows elapsed time for the run, targets
and captured stages. Times can include failures and recovery. Skipped or
unattempted targets, old logs without recorded timings, and interrupted runs
without end events report unknown duration rather than estimating it from
wall-clock timestamps. Stage durations need not sum to total target duration
because preflight and other work can occur between captured stages.

## `forge host update`

Runs the protected local Proxmox host update when `UPDATE_HOST=true`. Host rollback is intentionally unsupported. Host requirements are checked internally before mutation.

## `forge lxc list-targets`

Lists the automatic LXC scope controlled by `UPDATE_RUNNING_LXC`: currently running non-template containers only, excluding those specified in `EXCLUDE`. When this setting is `false`, the list is empty. Stopped containers are never selected automatically.

## `forge lxc update TARGET`

Runs one protected LXC update transaction independently of `UPDATE_RUNNING_LXC` and `EXCLUDE`, checking its recovery compatibility before starting or changing that LXC. If the explicitly selected LXC is stopped, Forge starts it temporarily, waits up to 30 seconds for a minimal `pct exec` readiness probe to succeed, performs the update while it is running, and returns it to stopped state afterwards. LXCs that were already running do not use this startup-readiness phase.

## `forge lxc update all`

Updates the LXC targets selected by `forge lxc list-targets` serially, without updating the Proxmox host. Respects `UPDATE_RUNNING_LXC`. Automatic updates never start stopped containers.

## `forge update all`

Validates configuration and freezes the currently running LXC VMID scope when `UPDATE_RUNNING_LXC=true`, updates the Proxmox host first if `UPDATE_HOST=true`, then updates those VMIDs serially. Automatic updates require a running LXC and never start a stopped container.

Successful host/LXC updates include `reboot_required=yes|no|unknown` in structured results and logs. Forge does not automatically reboot hosts or restart guests. The host check covers the Debian marker and newer installed Proxmox kernels.

Both bulk commands apply `EXCLUDE` by exact VMID or hostname during automatic selection, before any preflight, backup or guest update. The Proxmox host is not affected by `EXCLUDE`.

Both bulk commands check the entire selected running-LXC scope for free root filesystem space, available memory and recovery conflicts **before starting the host or any guest update**. If any LXC conflicts, the whole operation aborts before mutation. With `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true` (default), snapshot-incompatible LXCs use a `vzdump` recovery fallback only when preflight approves it; setting `false` blocks those LXCs.

In either bulk command, any failed LXC is recorded as failed regardless of its exit code. Forge attempts eligible guest recovery and continues with later LXC targets. In `forge update all`, a host update failure aborts the run before LXC processing.

Target inspection, host requirements and LXC requirements are internal workflows, not public CLI commands.

## `forge update self-update [BRANCH]`

Updates Forge from the configured Git remote using a guarded fast-forward.
The default branch is `main`; an explicitly supplied branch must contain
the currently installed commit. Refuses dirty worktrees, divergent history
or an unexpected remote. Does not run host or LXC updates.

Before an **interactive manual** `forge host update`, `forge lxc update`
or `forge update all`, `CHECK_FORGE_UPDATES_BEFORE_UPDATE=true` (default)
checks for a newer Forge `main` revision. If found, Forge asks whether to
update itself first, skip this version or cancel the system update.
A local `CHECK_FORGE_UPDATES_BEFORE_UPDATE=false` disables this prompt.
Scheduled and noninteractive runs never prompt or update Forge automatically.

## `forge update scheduled`

Executes only explicitly authorized targets: `SCHEDULED_UPDATE_HOST=true`
for the local host, and/or exact numeric VMIDs in `SCHEDULED_UPDATE_LXC`.
Both settings default to no authorization; an empty scheduled scope fails before
any updates. `EXCLUDE` still applies; stopped/template LXCs are always skipped.
An obsolete authorized VMID fails before host or LXC mutation. Manual selection
flags do not expand this scope. Same preflights, backups, recovery, lock and
final output as normal bulk updates; only scheduled target selection differs.

The optional systemd service/timer definitions are shipped in
[`systemd/`](../../systemd/README.md) but are not installed or enabled by Git
updates. Interactive `forge update all` remains unchanged.

## Operational checks

Useful read-only public CLI commands before an update:

```bash
forge validate-config
forge show-config
forge lxc list-targets
```

Host requirements, LXC inspection and LXC requirements remain internal workflows invoked as needed by updates.

For update failures, use the target log path printed by Forge. The primary log is intended to contain the complete stage sequence and the real result, rather than requiring the mutating command to be executed a second time for diagnosis.
