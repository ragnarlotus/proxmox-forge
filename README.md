# Forge

**Reliable Update Orchestration for Proxmox VE**

Forge is a Bash-based update orchestrator designed to run directly on a Proxmox VE host. Its current implementation updates the local Proxmox host and LXC containers through a protected, deterministic workflow with configuration validation, Proxmox-native backups, application updates, custom per-target scripts, health checks, recovery, post-update maintenance and structured logging.

Forge's responsibility is to **update and verify**, not to silently repair guest systems. When an eligible guest update fails and a same-run recovery artifact exists, Forge can restore that guest; otherwise it reports the real failure and leaves diagnosis or repair outside the updater.

The implementation status and broader roadmap are tracked in [`FEATURE_CHECKLIST.md`](FEATURE_CHECKLIST.md).

## Current scope

Forge currently supports:

- one local **Proxmox VE 9 / Debian 13** host;
- local **LXC containers** through `pct`, with automatic scope limited to running guests and explicit stopped-target updates supported;
- host updates through APT;
- LXC OS updates through APT;
- Proxmox Community Scripts applications exposing `/usr/bin/update`;
- target-specific local custom scripts;
- Proxmox-native LXC recovery backups;
- Forge-created host configuration backups;
- automatic LXC rollback after eligible failures;
- explicit updates of stopped LXCs with temporary startup and restoration of the original stopped state;
- post-update generic health checks and optional per-LXC functional checks (`health.d/<VMID>/*.sh`);
- APT `autoremove` maintenance;
- post-update LXC `fstrim`;
- per-target logging and deterministic terminal capture;
- one retained chronological general log per update execution (including sanitized stage output, target results and final table);
- read-only `forge status` / `forge history` queries over retained authoritative run logs, with optional JSON output;
- one global execution lock preventing overlapping Forge runs;
- optional, disabled-by-default systemd scheduled updates restricted to an explicit VMID allowlist.

Forge is an updater, not a tool for querying pending upgrades: standalone package-update discovery, preview/check, speculative upgrade plans, CVE reporting and package-level selection are outside its scope. APT repository metadata is refreshed as part of actual OS updates.

Not implemented yet:

- QEMU VM updates;
- external-host/SSH updates;
- cluster-wide orchestration;
- persistent background execution of manually started SSH jobs (F131);
- a Web UI;
- automatic Proxmox host rollback;
- automatic host reboot;
- generic pre/post hook frameworks;
- an automated test suite.

## Repository layout

```text
proxmox-forge/
├── forge                       # Public CLI and global runtime lock owner
├── forge.conf.default          # Versioned complete defaults
├── forge.conf                  # Optional local overrides; ignored by Git
├── FEATURE_CHECKLIST.md        # Capability/roadmap tracking
├── README.md
├── lib/
│   ├── backup/                 # Host and LXC backup/recovery helpers
│   ├── cli/                    # CLI help
│   ├── config/                 # Config loading/parsing/validation
│   ├── host/                   # Host preflight and update workflow
│   ├── logging/                # Structured logging and terminal capture
│   ├── lxc/                    # LXC discovery, update, health and maintenance
│   ├── runtime/                # Internal runtime-context validation
│   └── workflows/              # Higher-level orchestration
└── scripts.d/
    ├── README.md
    └── <VMID>/*.sh             # Local target-specific custom scripts
└── health.d/
    └── <VMID>/*.sh             # Optional guest functional health checks
```

The project is run directly from its checkout, without an installer or daemon. Optional disabled-by-default systemd timer/service templates are available in `systemd/` for separately authorized scheduled updates.

## Installation / checkout

The expected checkout location is `/opt/proxmox-forge`, which also matches the default custom-script path.

```bash
cd /opt
git clone git@github.com:ragnarlotus/proxmox-forge.git
cd /opt/proxmox-forge
./forge validate-config
```

To inspect effective settings without checking Proxmox guest state, use `./forge show-config`; it prints the merged configuration with each setting's default/override origin.

Forge must be run as `root` on the Proxmox host because it uses `pvesh`, `pct`, package management, host configuration backup and restore operations.

An optional convenience symlink can expose the CLI as `forge`:

```bash
ln -s /opt/proxmox-forge/forge /usr/local/bin/forge
```

The top-level `forge` script resolves launcher symbolic links to the real checkout before locating its components. Values such as `CUSTOM_SCRIPTS_DIR` remain configuration paths.

## LXC recovery policy

Forge creates a new `vzdump` recovery backup before any LXC mutation. The
applicable enabled Proxmox backup job determines its **storage, backup mode,
compression and retention**; Forge does not create persistent `Update_*`
snapshots or call `pct rollback`. A Proxmox job in `snapshot` mode may use
a **temporary** storage snapshot while producing the compressed archive; it
removes that temporary snapshot after backup completion.

With `ROLLBACK_ON_FAILURE=true`, the same-run `vzdump` archive can be
restored automatically if a mandatory stage fails, using the guarded advanced
`pct restore --force` helper and the usual functional health check. The
original update failure stays failed even if recovery succeeds. This requires
`CREATE_BACKUP_BEFORE_LXC_UPDATE=true`, an applicable Proxmox backup job, a
storage-backed rootfs and **no pre-existing persistent guest snapshots**
that forced restore could destroy. The preflight blocks unsafe updates and
`restore.sh` rechecks immediately before restoration. Forge never deletes
old snapshots automatically. After verifying their backups, users may choose
to remove old snapshots manually before the next update.

Running LXCs remain the automatic scope; stopped LXCs are updated only by
explicit request. See [Configuration](lib/config/README.md) and
[Backup and recovery](lib/backup/README.md).

## Updating Forge itself

Update the installed Forge checkout with:

```bash
forge update self-update
```

This updates `main` by default. An optional branch name (`forge update
self-update BRANCH`) selects that branch only when the update is a safe
fast-forward. Forge rejects unexpected remotes, dirty worktrees and divergent
history. Local `forge.conf` and ignored target-specific customizations are
preserved.

`CHECK_FORGE_UPDATES_BEFORE_UPDATE=true` by default: before an interactive
manual host or LXC update, Forge checks for a newer `main` revision and, if
one exists, asks whether to update Forge, continue without updating it or
cancel. Set the option to `false` in local `forge.conf` to disable the
prompt. Scheduled or noninteractive updates do not prompt or self-update.

Do not update Forge from a separate process while a Forge run is active; the
self-update command uses the existing global lock to prevent that.

## Documentation

| Section | Description |
| --- | --- |
| [CLI](lib/cli/README.md) | CLI commands and operations |
| [Optional scheduling](systemd/README.md) | Explicit scheduled authorization and systemd timer installation |
| [Configuration](lib/config/README.md) | Configuration and available options |
| [Host update](lib/host/README.md) | Proxmox host update |
| [LXC](lib/lxc/README.md) | LXC selection, updates and maintenance |
| [Backup and recovery](lib/backup/README.md) | Host/LXC backups, restore and recovery |
| [Workflows](lib/workflows/README.md) | Complete and LXC-only update runs |
| [Logging](lib/logging/README.md) | Logs and terminal output |
| [Runtime](lib/runtime/README.md) | Single-run execution model and safety |
| [Custom scripts](scripts.d/README.md) | Per-LXC extension scripts |
