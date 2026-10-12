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
- post-update health checks;
- APT `autoremove` maintenance;
- post-update LXC `fstrim`;
- per-target logging and deterministic terminal capture;
- one global execution lock preventing overlapping Forge runs.

Not implemented yet:

- QEMU VM updates;
- external-host/SSH updates;
- cluster-wide orchestration;
- package update preview/discovery, CVE reporting or package-level selection;
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

Forge must be run as `root` on the Proxmox host because it uses `pvesh`, `pct`, package management, host configuration backup and restore operations.

An optional convenience symlink can expose the CLI as `forge`:

```bash
ln -s /opt/proxmox-forge/forge /usr/local/bin/forge
```

The top-level `forge` script locates the rest of the project relative to itself; only values such as `CUSTOM_SCRIPTS_DIR` remain configuration paths.

## LXC recovery policy

`BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true` is the default. Forge uses a persistent Proxmox `Update_*` snapshot for snapshot-capable LXCs and, when safe, the same-run Proxmox `vzdump` backup for snapshot-incompatible LXCs. The read-only `forge validate-config` command reports snapshot/backup-policy conflicts among running LXCs selected for bulk updates and blocks unsafe runs before any host or guest mutation.

To require persistent snapshots for every selected LXC and block snapshot-incompatible targets, set the optional local override:

```bash
BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=false
```

The backup-only recovery fallback requires `CREATE_BACKUP_BEFORE_LXC_UPDATE=true`, a valid applicable Proxmox backup job, and **no existing persistent snapshots that a forced restore could destroy**. The advanced restore helper preserves excluded storage-backed volumes and checks for persistent snapshots again before restoring. Running LXCs remain the only automatic targets; stopped LXCs are checked only when explicitly requested. See [Configuration](lib/config/README.md) and [Backup and recovery](lib/backup/README.md).

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
