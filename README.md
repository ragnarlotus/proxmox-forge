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
