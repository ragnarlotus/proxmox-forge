# Forge

**Reliable Update Orchestration for Proxmox VE**

Forge is a Bash-based update orchestrator for a local **Proxmox VE 9 / Debian 13** host and its LXC containers. It updates and verifies systems, creates recovery backups, and reports real failures without hiding them behind a successful rollback.

The [feature checklist](FEATURE_CHECKLIST.md) tracks implemented capabilities, acceptance status and future work.

## Current capabilities

- **Host and LXC updates:** APT-based operating-system updates, Community Scripts application updaters (`/usr/bin/update`), optional per-LXC custom scripts and `apt-get autoremove`.
- **Selection and lifecycle:** running LXCs in automatic runs; explicit updates of stopped LXCs with temporary startup and restoration of their original state; exclusions and scheduled allowlists.
- **Backup and recovery:** Proxmox-job-based `vzdump` recovery archives for guests, optional automatic restore after eligible LXC failures, and Forge-created host configuration backups. Host rollback is not supported.
- **Preflight and verification:** disk/memory checks, backup/restore safety validation, optional temporary CPU/RAM increases for LXC updates, service and functional health checks, reboot-needed detection and LXC `fstrim`.
- **Results and diagnostics:** per-target and per-run logs, configurable retention, elapsed times, actual APT upgrade counts, detected application versions, actionable errors, and `forge status` / `forge history` (including JSON output).
- **Console experience:** compact live progress for interactive manual updates; `FORGE_OUTPUT_MODE=full` restores detailed terminal output without changing the stored logs.
- **Languages (F246):** English by default, optional Spanish using `LANGUAGE=es` in `forge.conf`, with stable technical records and JSON.
- **Execution safety:** a single global lock, optional reattachable manual update sessions through `tmux` and `forge back`, and protected self-updates from Git.
- **Automation and notifications:** optional explicitly authorized systemd scheduling (disabled until installed/enabled) and configurable final root-mail notifications through the existing Proxmox mail routing.
- **Tests:** automated unit/integration regression tests in `tests/`, executed through GitHub Actions, alongside selected real-host acceptance checks.

Forge is an updater, not a pending-upgrade preview tool. It does not provide standalone package-update discovery, CVE reporting or package-by-package selection.

Not currently supported: QEMU VM updates, remote/SSH host updates, cluster orchestration, a Web UI, automatic Proxmox host rollback/reboot, or a generic pre/post-hook framework.

## Repository layout

```text
proxmox-forge/
├── forge                       # Public CLI and global lock owner
├── forge.conf.default          # Git-tracked default configuration
├── forge.conf                  # Optional local overrides (Git-ignored)
├── FEATURE_CHECKLIST.md
├── README.md
├── lib/
│   ├── backup/                 # Host and LXC backup/restore helpers
│   ├── cli/                    # CLI help and documentation
│   ├── config/                 # Configuration and preflight policy
│   ├── host/                   # Host update
│   ├── i18n/                   # English/Spanish presentation catalogues
│   ├── logging/                # Complete output capture and retained logs
│   ├── lxc/                    # Guest updates and lifecycle
│   ├── runtime/                # Locking and persistent sessions
│   ├── ui/                     # Compact live terminal presentation
│   └── workflows/              # Bulk update orchestration
├── health.d/                   # Local per-LXC functional checks
├── scripts.d/                  # Local per-LXC custom update scripts
├── systemd/                    # Optional scheduled update unit/timer
└── tests/                      # Automated regression tests
```

Forge runs directly from its checkout; there is no application installer or always-on web service. The optional systemd components only enable explicitly authorized scheduled updates or short-lived persistent manual sessions.

## Installation / checkout

The expected checkout location is `/opt/proxmox-forge`. Run as `root` on the Proxmox host:

```bash
cd /opt
git clone git@github.com:ragnarlotus/proxmox-forge.git
cd /opt/proxmox-forge
./forge validate-config
```

The checkout requires Git authentication appropriate for its configured remote. A read-only deploy key is sufficient for updates; Forge does not need Git write access on the Proxmox host.

Put host-specific overrides in the Git-ignored `forge.conf`, not `forge.conf.default`. Inspect the effective configuration with `./forge show-config`.

An optional symlink makes `forge` available on `PATH`:

```bash
ln -s /opt/proxmox-forge/forge /usr/local/bin/forge
```

The launcher resolves this symlink to the real checkout before loading internal files.

## Updating Forge itself

```bash
forge update self-update
```

By default this fast-forwards the installed checkout to `main`. An optional branch argument is accepted only if the requested branch safely contains the installed revision. Tracked local changes, unexpected remotes and divergent history block the operation; Git-ignored local configuration and scripts remain untouched unless an incoming tracked path conflicts.

With `CHECK_FORGE_UPDATES_BEFORE_UPDATE=true` (the default), interactive manual updates check for a newer Forge `main` revision and ask whether to self-update first, skip that version or cancel. Scheduled and noninteractive updates do not prompt or self-update. The existing global lock prevents self-updating during another Forge execution.

For commands and output modes, see the [CLI reference](lib/cli/README.md).

## Documentation

| Section | Description |
| --- | --- |
| [CLI](lib/cli/README.md) | Commands, interactive progress, results and self-update |
| [Configuration](lib/config/README.md) | Defaults, local overrides, validation and options |
| [Languages](lib/i18n/README.md) | English/Spanish presentation, translation catalogues and technical output |
| [Backup and recovery](lib/backup/README.md) | Host backup/restore and the **LXC recovery policy** |
| [Runtime and safety](lib/runtime/README.md) | Global lock and **persistent manual updates (F131)** |
| [Host update](lib/host/README.md) | Local Proxmox host update and reboot notices |
| [LXC](lib/lxc/README.md) | Guest selection, lifecycle, updates and maintenance |
| [Workflows](lib/workflows/README.md) | Full and LXC-only bulk runs and failure handling |
| [Logging](lib/logging/README.md) | Full logs, retention and console capture |
| [Optional scheduling](systemd/README.md) | Authorized systemd service and timer |
| [Custom scripts](scripts.d/README.md) | Per-LXC update scripts |
| [Functional health checks](health.d/README.md) | Optional per-LXC service/application verification |
