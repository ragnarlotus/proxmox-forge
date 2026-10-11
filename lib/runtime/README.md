# Runtime and safety

## Single-run execution model

`forge` is the only normal public entry point. Every invocation acquires the same non-blocking global lock before dispatching any command, including read-only commands. While one Forge execution is active, another invocation fails immediately instead of waiting or running concurrently.

All `lib/**/*.sh` files are internal implementation components and require the runtime context inherited from the owning `forge` process. They are deliberately not standalone command-line entry points.

The sole exception is:

```text
lib/backup/host/restore.sh
```

That script must remain independently runnable for PVE disaster recovery after a clean reinstall. When invoked directly it acquires the same global lock and creates the same runtime context for any internal helpers it uses, so host restoration still cannot overlap another Forge execution.

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
- a host failure aborts `forge update all` before guest processing;
- Forge never performs guest-style rollback on the host;
- no automatic host reboot is performed;
- post-update `fstrim` failure is non-destructive and non-rollback-triggering;
- local configuration and custom scripts are kept outside versioned source state.
