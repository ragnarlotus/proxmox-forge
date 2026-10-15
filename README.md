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
- one global execution lock preventing overlapping Forge runs.

Forge is an updater, not a tool for querying pending upgrades: standalone package-update discovery, preview/check, speculative upgrade plans, CVE reporting and package-level selection are outside its scope. APT repository metadata is refreshed as part of actual OS updates.

Not implemented yet:

- QEMU VM updates;
- external-host/SSH updates;
- cluster-wide orchestration;
- scheduling/background execution;
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

The project is currently run directly from its checkout. There is no installer, daemon or service layer.

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

The top-level `forge` script locates the rest of the project relative to itself; only values such as `CUSTOM_SCRIPTS_DIR` remain configuration paths.

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

Forge does not yet implement a self-update command. Update the checkout explicitly:

```bash
cd /opt/proxmox-forge
git pull --ff-only
./forge validate-config
```

Because `forge.conf` and target-specific `scripts.d/` contents are ignored by Git, normal fast-forward source updates preserve local host configuration and local target extensions.

Do not pull new code into the checkout while any Forge execution is in progress: child stages in the active run must continue using the same source revision from start to finish.

## Documentation

| Section | Description |
| --- | --- |
| [CLI](lib/cli/README.md) | CLI commands and operations |
| [Configuration](lib/config/README.md) | Configuration and available options |
| [Host update](lib/host/README.md) | Proxmox host update |
| [LXC](lib/lxc/README.md) | LXC selection, updates and maintenance |
| [Backup and recovery](lib/backup/README.md) | Host/LXC backups, restore and recovery |
| [Workflows](lib/workflows/README.md) | Complete and LXC-only update runs |
| [Logging](lib/logging/README.md) | Logs and terminal output |
| [Runtime](lib/runtime/README.md) | Single-run execution model and safety |
| [Custom scripts](scripts.d/README.md) | Per-LXC extension scripts |
