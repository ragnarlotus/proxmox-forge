# Forge

**Reliable Update Orchestration for Proxmox VE**

Forge is a Bash-based update orchestrator designed to run directly on a Proxmox VE host. Its current implementation updates the local Proxmox host and running LXC containers through a protected, deterministic workflow with configuration validation, Proxmox-native backups, application updates, custom per-target scripts, health checks, recovery, post-update maintenance and structured logging.

Forge's responsibility is to **update and verify**, not to silently repair guest systems. When an eligible guest update fails and a same-run recovery artifact exists, Forge can restore that guest; otherwise it reports the real failure and leaves diagnosis or repair outside the updater.

The implementation status and broader roadmap are tracked in [`FEATURE_CHECKLIST.md`](FEATURE_CHECKLIST.md).

## Current scope

Forge currently supports:

- one local **Proxmox VE 9 / Debian 13** host;
- local **running LXC containers** through `pct`;
- host updates through APT;
- LXC OS updates through APT;
- Proxmox Community Scripts applications exposing `/usr/bin/update`;
- target-specific local custom scripts;
- Proxmox-native LXC recovery backups;
- Forge-created host configuration backups;
- automatic LXC rollback after eligible failures;
- post-update health checks;
- APT `autoremove` maintenance;
- post-update LXC `fstrim`;
- per-target logging and deterministic terminal capture;
- one global execution lock preventing overlapping Forge runs.

Not implemented yet:

- QEMU VM updates;
- external-host/SSH updates;
- updating stopped LXCs;
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

## CLI

```text
forge validate-config
forge check-host-requirements
forge update-host
forge list-lxc-targets
forge inspect-target TARGET
forge check-requirements TARGET
forge update TARGET
forge update-all
forge help
```

`TARGET` may be either:

- an exact numeric Proxmox VMID; or
- an exact LXC hostname.

Partial, prefix and fuzzy matching are deliberately forbidden. An unknown target fails, and an ambiguous exact hostname also fails.

### Single-run execution model

`forge` is the only normal public entry point. Every invocation acquires the same non-blocking global lock before dispatching any command, including read-only commands. While one Forge execution is active, another invocation fails immediately instead of waiting or running concurrently.

All `lib/**/*.sh` files are internal implementation components and require the runtime context inherited from the owning `forge` process. They are deliberately not standalone command-line entry points.

The sole exception is:

```text
lib/backup/host/restore.sh
```

That script must remain independently runnable for PVE disaster recovery after a clean reinstall. When invoked directly it acquires the same global lock and creates the same runtime context for any internal helpers it uses, so host restoration still cannot overlap another Forge execution.

### `validate-config`

Loads `forge.conf.default`, then optional local `forge.conf`, validates the merged result and performs no update.

### `check-host-requirements`

Runs the current read-only host preflight. The host must currently be Proxmox VE 9 on Debian 13, have a clean `dpkg --audit` result and have no conflicting APT/DPKG process.

### `list-lxc-targets`

Lists the automatic LXC scope controlled by `UPDATE_RUNNING_LXC`: currently running non-template containers only. Stopped containers are never selected automatically.

### `inspect-target TARGET`

Collects the currently available information for one running LXC: identity, state, OS/version, root free space, available memory, package-manager status, Community Scripts updater presence and Forge custom-script presence.

### `check-requirements TARGET`

Runs the read-only LXC requirements workflow. It rejects unsupported package managers, DPKG audit problems and active conflicting package-manager processes.

### `update TARGET`

Runs one protected LXC update transaction independently of `UPDATE_RUNNING_LXC`. If the explicitly selected LXC is stopped, Forge starts it temporarily, performs the update while it is running, and returns it to stopped state afterwards.

### `update-host`

Runs the protected local Proxmox host update. Host rollback is intentionally unsupported.

### `update-all`

Validates configuration and freezes the currently running LXC VMID scope when `UPDATE_RUNNING_LXC=true`, updates the Proxmox host first, then updates those VMIDs serially. Each selected LXC is resolved again when its own turn begins; if it has become stopped meanwhile, `update-all` skips it instead of starting it.

If the host update fails, LXC processing does not start. If an individual LXC fails, Forge preserves that failure, attempts guest recovery when applicable, continues with later LXCs and returns a failed aggregate result at the end.

## Configuration model

Forge uses a versioned-defaults plus local-overrides model:

```text
/opt/proxmox-forge/forge.conf.default   # tracked by Git
/opt/proxmox-forge/forge.conf           # optional, host-local, ignored by Git
```

`forge.conf.default` is the complete source of default values and should not be edited for host-specific customization. `forge.conf`, when present, is loaded afterwards and only needs to contain values that differ from the defaults.

Example local override:

```bash
UPDATE_HOST=false
HOST_BACKUP_EXTRA_PATHS="/opt/custom,/srv/config"
LOG_KEEP=12
```

Rules:

- keys must use the supported uppercase configuration schema;
- duplicate keys inside the same file are errors;
- a key in `forge.conf` may override the same key from `forge.conf.default`;
- unknown keys are errors;
- required keys must exist in the merged configuration;
- booleans must be exactly `true` or `false`;
- `CUSTOM_SCRIPTS_DIR` and `LOG_DIR` must be absolute paths;
- each non-empty `HOST_BACKUP_EXTRA_PATHS` entry must be an absolute path;
- `LOG_KEEP` must be a positive integer.

Because `forge.conf` is Git-ignored, normal `git pull --ff-only` updates do not replace local overrides. Target-specific contents below `scripts.d/` are also ignored except for `scripts.d/README.md`.

### Current configuration keys

| Key | Type / accepted value | Purpose |
| --- | --- | --- |
| `UPDATE_HOST` | Boolean: `true` or `false` | Enable local Proxmox host updates. |
| `UPDATE_RUNNING_LXC` | Boolean: `true` or `false` | Include currently running LXCs in automatic `list-lxc-targets` / `update-all` scope. It does not restrict explicit `forge update TARGET`. |
| `UPDATE_LXC_OS` | Boolean: `true` or `false` | Run the LXC OS/package-manager stage. |
| `UPDATE_LXC_APPLICATION` | Boolean: `true` or `false` | Run the detected Community Scripts application updater. |
| `RUN_CUSTOM_SCRIPTS` | Boolean: `true` or `false` | Run local `scripts.d/<VMID>/*.sh` scripts. |
| `CUSTOM_SCRIPTS_DIR` | Absolute path | Absolute directory containing per-target custom scripts. |
| `CHECK_LXC_REQUIREMENTS` | Boolean: `true` or `false` | Run read-only LXC requirements before mutation. |
| `CREATE_BACKUP_BEFORE_HOST_UPDATE` | Boolean: `true` or `false` | Create and validate a host configuration backup before host package changes. |
| `HOST_BACKUP_EXTRA_PATHS` | Empty string or comma-separated absolute paths | Optional paths appended to the fixed host-backup path set. Example: `/opt/custom,/srv/config`. |
| `CREATE_BACKUP_BEFORE_LXC_UPDATE` | Boolean: `true` or `false` | Create a Proxmox recovery backup before LXC mutation. |
| `ROLLBACK_ON_FAILURE` | Boolean: `true` or `false` | Attempt same-run guest recovery after eligible update/health failures. |
| `HEALTH_CHECK` | Boolean: `true` or `false` | Verify target health after mutation. |
| `LOG_DIR` | Absolute path | Base Forge log directory. |
| `LOG_KEEP` | Positive integer (`>= 1`) | Number of timestamped logs retained per LXC. |

## Host update workflow

The current host workflow is:

```text
validate configuration
→ host requirements
→ host configuration backup
→ apt-get update
→ apt-get full-upgrade
→ apt-get autoremove
→ post-update host requirements/health
→ success
```

APT runs non-interactively with configuration-file handling set to keep existing local configuration when package defaults differ.

Forge does **not** reboot the Proxmox host automatically. A newly installed kernel therefore becomes active only after a separately controlled reboot.

### Host configuration backup

Before a host update, Forge derives the backup destination from enabled Proxmox backup jobs applying to the local node. There must be exactly one distinct applicable backup storage; Forge refuses to choose implicitly if multiple storages are configured.

The archive is stored under the selected storage's filesystem path:

```text
<storage-path>/pve/<hostname>-config-YYYY-MM-DD_HH-MM-SS.tar.gz
```

The mandatory base archive paths are:

```text
/etc/
/root
/var/lib/pve-cluster
/usr/local/bin
```

`HOST_BACKUP_EXTRA_PATHS` may append host-local files or directories to this set without replacing the mandatory paths. Its value is a comma-separated list of absolute paths, for example:

```bash
HOST_BACKUP_EXTRA_PATHS="/opt/custom,/srv/config"
```

Every configured additional path must exist when the backup is created; a missing configured path makes the backup fail rather than being silently omitted.

Forge verifies that the archive exists, is non-empty and can be listed by `tar` before the update proceeds. Forge-created host configuration archives older than 14 days are removed after a new archive has been validated.

Host failures are reported as failures with `rollback=unsupported`; Forge never pretends that LXC restore semantics apply to the Proxmox host.

### Restoring a Proxmox VE host

To restore a PVE host from a Forge host backup after a rebuild, first install Proxmox VE, then install/clone Proxmox Forge on the new host and run:

```bash
cd /opt/proxmox-forge
bash lib/backup/host/restore.sh
```

The restore script then guides the remaining PVE recovery process. This is a manual recovery procedure, not automatic host rollback. It is the only `lib/` script intended to be started directly and it participates in the same global Forge execution lock.

## LXC update workflow

For one explicitly selected LXC, the current workflow is:

```text
validate configuration and resolve exact target/current state
→ if stopped, start temporarily
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

`UPDATE_RUNNING_LXC` applies only to automatic target discovery for `list-lxc-targets` and `update-all`. It does not block `forge update TARGET`.

The recovery backup is created whenever at least one mutating LXC stage is enabled and `CREATE_BACKUP_BEFORE_LXC_UPDATE=true`.

### Package-manager update strategies

Forge currently supports APT-based LXCs only.

| Package manager | Update sequence |
| --- | --- |
| APT | `apt-get update` → `apt-get dist-upgrade` → `apt-get autoremove` |

APT runs non-interactively and preserves existing local configuration files when package defaults differ.

A non-APT LXC is rejected by requirements before the update begins.

### Community Scripts application update

For a running LXC, Forge detects an executable `/usr/bin/update`. When present and application updates are enabled, it runs:

```text
env PHS_SILENT=1 /usr/bin/update
```

through `pct exec` with standard input detached.

A non-zero application-updater exit code is authoritative: the target fails and same-run recovery is attempted when enabled and available.

### Custom scripts

Target-specific extensions live under:

```text
scripts.d/<VMID>/*.sh
```

Only regular files ending exactly in `.sh` are executed, in lexical order. Each script is streamed into the target container and run with Bash.

A non-zero custom-script result fails the target and participates in the same recovery semantics as the normal update stages.

The actual target-specific scripts are local data and are intentionally not versioned by this repository.

### Health check

The current generic post-update LXC health check verifies that:

- the LXC is still in `running` state;
- `pct exec` succeeds;
- when systemd is active inside the LXC, there are no failed systemd service units.

A mandatory health failure is an update failure and can trigger rollback when configured.

### Post-update filesystem trim

After an otherwise successful LXC mutation and health check, Forge runs:

```text
pct fstrim <VMID>
```

This is storage maintenance, not backup pruning. It returns filesystem blocks that are no longer in use to the underlying storage where supported.

A `fstrim` failure is logged and reported as a **warning**. Forge deliberately does not restore an otherwise healthy guest merely because trim failed.

## LXC backup and recovery semantics

Forge does not maintain a second, competing LXC backup policy. Proxmox remains authoritative.

For each LXC, Forge reads enabled Proxmox backup jobs and requires exactly one applicable job. It builds a one-target `vzdump` command from the job options exposed by the installed `vzdump` CLI, including the configured storage and applicable backup behaviour.

The important guarantees are:

- `vzdump` runs synchronously and its exit status is authoritative;
- the exact newly created recovery volume is identified by comparing backup volumes before and after `vzdump`;
- backup creation is limited to creating and identifying the recovery artifact; guest health is validated later by the update workflow;
- the exact recovery artifact is retained for possible same-run rollback;
- Forge does not implement a separate LXC backup-retention system; applicable Proxmox job options remain authoritative.

If a required OS, application, custom-script or health stage fails and `ROLLBACK_ON_FAILURE=true`, Forge attempts recovery from the backup created for that same run.

Recovery success does **not** convert the original update failure into success. The target remains failed, preserving the primary result, and `update-all` may continue with later targets. For an explicitly selected LXC that was originally stopped, Forge also attempts to restore that stopped state after success or failure/recovery.

## `update-all` failure model

`update-all` deliberately has asymmetric host and guest semantics:

```text
freeze effective VMID scope
        │
        ▼
update host
   │
   ├─ failure → abort global run before any LXC starts
   │
   ▼
update LXCs serially
   │
   ├─ target failure → recover if possible, record failure, continue
   │
   └─ remaining targets continue
        │
        ▼
aggregate final result
```

This means `continue after guest failure` never means `convert failure into success`.

## Logging and terminal output

Default base directory:

```text
/var/log/proxmox-forge
```

Host logs:

```text
LOG_DIR/<PVE_FQDN>/host/common.log
LOG_DIR/<PVE_FQDN>/host/error.log
```

LXC logs:

```text
LOG_DIR/<PVE_FQDN>/lxc/<VMID>/<TIMESTAMP>.log
```

`LOG_KEEP` controls retention of timestamped per-LXC logs.

Forge records structured events with ISO timestamps, event names, fields, exit codes and durations where available. Host `ERROR` events are mirrored to `error.log`.

### Terminal capture behaviour

Update output is streamed live rather than buffered until the command finishes.

The terminal path preserves producer formatting such as:

- ANSI colours;
- carriage-return progress redraws;
- spinner/redraw behaviour;
- normal screen repaint sequences.

Forge filters only the terminal `CSI 3 J` sequence that clears scrollback. This allows Community Scripts headers to repaint without deleting the earlier `update-all` history from the terminal's scrollback buffer.

The persistent log receives a sanitized copy: ANSI control sequences are removed and carriage-return progress is collapsed so the log contains the final visible state instead of a separate fake line for every progress percentage.

Command stdout and stderr are captured as one combined terminal/log stream, while the command's real exit code remains authoritative.

## Filesystem trim vs backup retention

These are separate operations:

- **`pct fstrim`** reclaims unused guest filesystem blocks from the underlying storage where supported;
- **Proxmox backup prune/retention** removes old backup archives according to backup policy;
- **Forge host configuration backup retention** removes Forge-created host configuration archives older than 14 days.

Running `fstrim` after an update does not delete backup archives and is not a replacement for backup retention.

## Updating Forge itself

Forge does not yet implement a self-update command. Update the checkout explicitly:

```bash
cd /opt/proxmox-forge
git pull --ff-only
./forge validate-config
```

Because `forge.conf` and target-specific `scripts.d/` contents are ignored by Git, normal fast-forward source updates preserve local host configuration and local target extensions.

Do not pull new code into the checkout while any Forge execution is in progress: child stages in the active run must continue using the same source revision from start to finish.

## Operational checks

Useful read-only diagnostics before an update:

```bash
forge validate-config
forge check-host-requirements
forge list-lxc-targets
forge inspect-target <VMID-or-name>
forge check-requirements <VMID-or-name>
```

For update failures, use the target log path printed by Forge. The primary log is intended to contain the complete stage sequence and the real result, rather than requiring the mutating command to be executed a second time for diagnosis.

## Safety properties

Current implementation deliberately enforces these rules:

- only one Forge execution may hold the global runtime lock at a time;
- `forge` is the normal public entry point and internal `lib/**/*.sh` components reject direct execution;
- the standalone PVE restore utility is the sole internal exception and acquires the same global lock itself;
- configuration and the effective LXC VMID scope are frozen before mutation, while each selected LXC's current existence, name, state and template flag are revalidated when its own update begins;
- LXC templates are never update targets;
- stopped LXCs are excluded from automatic `update-all` scope; an explicitly selected stopped LXC is temporarily started for its update and returned to stopped state afterwards;
- package managers run non-interactively;
- mutating commands are not repeated merely to capture errors;
- synchronous `vzdump` completion and the newly created recovery volume are both validated;
- guest failures remain failures even if recovery succeeds;
- a host failure aborts `update-all` before guest processing;
- Forge never performs guest-style rollback on the host;
- no automatic host reboot is performed;
- post-update `fstrim` failure is non-destructive and non-rollback-triggering;
- local configuration and custom scripts are kept outside versioned source state.

## Validation status

The current critical path has been manually exercised on a live Proxmox system, including:

- complete `update-all` execution;
- deliberate LXC systemd health failure detection and recovery;
- real-time carriage-return progress handling;
- sanitized persistent logging;
- terminal scrollback preservation across Community Scripts screen clears;
- host APT `autoremove` after simulation and boot-kernel validation;
- LXC APT `autoremove` simulation;
- real LXC `pct fstrim` execution.

There is not yet a repeatable automated unit/integration/end-to-end test suite. That remains tracked in [`FEATURE_CHECKLIST.md`](FEATURE_CHECKLIST.md).