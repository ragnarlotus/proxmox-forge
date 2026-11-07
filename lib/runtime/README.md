# Runtime and safety

## Single-run execution model

`forge` is the only normal public entry point. Every invocation acquires the same non-blocking global lock before dispatching any command, including read-only commands. While one Forge execution is active, another invocation fails immediately instead of waiting or running concurrently.

All `lib/**/*.sh` files are internal implementation components and require the runtime context inherited from the owning `forge` process. They are deliberately not standalone command-line entry points.

The active lock is held on file descriptor 200 throughout an invocation.
Forge's internal helpers inherit it to validate the runtime guard. Every `pct exec` boundary closes descriptor 200 **for the
spawned guest command only**, after its owning Forge helper has passed that
guard. Direct `pct start`/`stop`/`shutdown` stages dispatched through the
capture helper close the same descriptor for the `pct` subprocess. This prevents application updaters, custom health scripts and background
daemons started within LXCs (for example Nx) from retaining Forge's lock after
the owning update process exits. Do not close the descriptor before running
an internal Forge helper: that would bypass its guard and break the single-run
safety model. Closing the descriptor for the guest does not release the lock
while Forge is still running.

The sole exception is:

```text
lib/backup/host/restore.sh
```

That script must remain independently runnable for PVE disaster recovery after a clean reinstall. When invoked directly it acquires the same global lock and creates the same runtime context for any internal helpers it uses, so host restoration still cannot overlap another Forge execution.

## Persistent manual update sessions (F131)

Set `PERSISTENT_UPDATE_SESSION=true` in the Git-ignored `forge.conf` to run
manual `forge host update`, `forge lxc update TARGET|all` and
`forge update all` inside a reattachable tmux session hosted by a transient
systemd service. The setting defaults to `false`, in which case those updates
run directly in the invoking terminal.

The terminal displays live progress. If SSH disconnects, the update continues
in its independent systemd-managed tmux session. After reconnecting,
`forge back` reattaches to the **currently active** update without launching
another update or acquiring its already-held global lock. If no update is active
(including after completion), use `forge history` to inspect the saved result.
Completed tmux sessions are not retained.

Each persistent start verifies that tmux can run for the current user under
`system.slice`, outside the SSH login scope, before mutating anything. A
missing dependency or failed independence check blocks the update rather than
silently falling back to a foreground job. A second manual update detects the
active persistent session and directs the operator to `forge back`.

Only manual host/LXC/bulk updates use this mode. Read-only CLI commands,
`forge self-update` and systemd-scheduled updates do not start tmux
sessions. No automatic resume occurs after a host reboot.

The compact interactive progress view also works through `forge back`.
The worker loads validated `LANGUAGE=en|es` from the host-local configuration;
reconnecting does not change the selected language.
Set `FORGE_OUTPUT_MODE=full` when launching a manual update to retain the
detailed terminal stream in its tmux session; both views preserve the same
complete run logs and authoritative exit status.

## Safety properties

Current implementation deliberately enforces these rules:

- only one Forge execution may hold the global runtime lock at a time;
- `forge` is the normal public entry point and internal `lib/**/*.sh` components reject direct execution;
- the standalone PVE restore utility is the sole internal exception and acquires the same global lock itself;
- configuration and the effective LXC VMID scope are frozen before mutation, while each selected LXC's current existence, name, state and template flag are revalidated when its own update begins;
- LXC templates are never update targets;
- stopped LXCs are excluded from the bulk-update scope; an explicitly selected stopped LXC is temporarily started, must become reachable through `pct exec` within 30 seconds before requirements begin, and is returned to stopped state afterwards;
- package managers run non-interactively;
- mutating commands are not repeated merely to capture errors;
- synchronous `vzdump` completion and the newly created recovery volume are both validated;
- guest failures remain failures even if recovery succeeds;
- a host failure remains failed but does not prevent independently preflight-approved LXCs from updating in `forge update all`;
- Forge never performs guest-style rollback on the host;
- no automatic host reboot is performed;
- post-update `fstrim` failure is non-destructive and non-rollback-triggering;
- local configuration and custom scripts are kept outside versioned source state.
