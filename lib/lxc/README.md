# LXC update workflow


For one explicitly selected LXC, the current workflow is:

```text
validate configuration and resolve exact target/current state
→ if stopped, start temporarily
→ if Forge started it, wait for pct exec readiness (bounded to 30 seconds)
→ read-only requirements
→ recovery backup
→ OS/package update
→ application update
→ target-specific custom scripts
→ health check
→ pct fstrim
→ if originally stopped, stop again
→ success
```

`UPDATE_RUNNING_LXC` applies only to automatic target discovery for `forge lxc list-targets` and both bulk update commands. It does not block `forge lxc update TARGET`.

The recovery backup is created whenever at least one mutating LXC stage is enabled and `CREATE_BACKUP_BEFORE_LXC_UPDATE=true`.

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

When `RUN_CUSTOM_SCRIPTS=true`, the LXC update workflow checks for eligible scripts before planning the recovery backup, independently of `CHECK_LXC_REQUIREMENTS`. The custom-script executor then selects and runs the scripts at the custom-script stage.

Only regular files ending exactly in `.sh` are executed, in lexical order. Each script is streamed into the target container and run with Bash.

A non-zero custom-script result fails the target and participates in the same recovery semantics as the normal update stages.

The actual target-specific scripts are local data and are intentionally not versioned by this repository.

## Health check

The current generic post-update LXC health check verifies that:

- the LXC is still in `running` state;
- `pct exec` succeeds;
- when systemd is active inside the LXC, there are no failed systemd service units.

A mandatory health failure is an update failure and can trigger rollback when configured.

## Post-update filesystem trim

After an otherwise successful LXC mutation and health check, Forge runs:

```text
pct fstrim <VMID>
```

This is storage maintenance, not backup pruning. It returns filesystem blocks that are no longer in use to the underlying storage where supported.

A `fstrim` failure is logged and reported as a **warning**. Forge deliberately does not restore an otherwise healthy guest merely because trim failed.
