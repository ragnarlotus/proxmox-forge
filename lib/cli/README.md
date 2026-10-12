# Forge CLI


```text
forge validate-config
forge show-config
forge host update
forge lxc list-targets
forge lxc update TARGET
forge lxc update all
forge update all
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

## Operational checks

Useful read-only public CLI commands before an update:

```bash
forge validate-config
forge show-config
forge lxc list-targets
```

Host requirements, LXC inspection and LXC requirements remain internal workflows invoked as needed by updates.

For update failures, use the target log path printed by Forge. The primary log is intended to contain the complete stage sequence and the real result, rather than requiring the mutating command to be executed a second time for diagnosis.
