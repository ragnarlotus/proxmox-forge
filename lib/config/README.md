# Configuration model


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
- `NOTIFY_MANUAL` and `NOTIFY_SCHEDULED` accept only `none`, `errors` or `all`; the obsolete `NOTIFY_ONLY_ERRORS` key is no longer accepted;
- `CUSTOM_SCRIPTS_DIR`, `HEALTH_SCRIPTS_DIR` and `LOG_DIR` must be absolute paths;
- each non-empty `HOST_BACKUP_EXTRA_PATHS` entry must be an absolute path;
- `EXCLUDE` must be empty or comma-separated exact VMIDs/hostnames. Spaces around entries are accepted; empty entries, wildcards and spaces inside names are rejected;
- `LOG_KEEP` must be a positive integer;
- `MIN_ROOT_FREE_MB` and `MIN_MEM_AVAILABLE_MB` must each be integers from 1 to 1048576 MiB.

Run `forge show-config` to print the validated effective settings (defaults merged with local overrides) in alphabetical order. Each line is a shell-escaped `KEY=value` assignment followed by `# source=default` or `# source=override`. An override is marked even if it repeats the default value. Sensitive-looking keys (passwords, tokens, secrets and credentials) are redacted. This read-only command does not query Proxmox guest state or run the `validate-config` LXC recovery-policy preflight; it only validates configuration syntax and values.

Because `forge.conf` is Git-ignored, normal `git pull --ff-only` updates do not replace local overrides. Target-specific contents below `scripts.d/` and `health.d/` are also ignored except for their README files.

## Current configuration keys

LXC requirements checks are mandatory before backup or mutation.
`forge validate-config` checks backup-policy and backup-only recovery
compatibility for the running LXCs in automatic scope. With automatic
recovery enabled, selected guests retaining persistent snapshots block
updates because `pct restore --force` could destroy those snapshots. Forge
never removes them. Bulk and explicit LXC updates perform the same check;
stopped LXCs are checked only when explicitly selected. Backup creation is
required before LXC mutation even if automatic rollback is disabled.
`validate-config` is read-only.

| Key | Type / accepted value | Purpose |
| --- | --- | --- |
| `UPDATE_HOST` | Boolean: `true` or `false` | Enable local Proxmox host updates. |
| `SCHEDULED_UPDATE_HOST` | Boolean, default `false` | Allow host updates in the separate scheduled workflow. |
| `SCHEDULED_UPDATE_LXC` | Empty string or comma-separated numeric VMIDs | Positive allowlist for scheduled LXC updates, independent of manual discovery. |
| `PERSISTENT_UPDATE_SESSION` | Boolean, default `false` | Opt into systemd-managed tmux sessions for **manual updates only**. Requires a working independent systemd service and tmux for the executing user; otherwise updates fail before mutation. Use `forge back` while running or `forge history` after completion. |
| `CHECK_FORGE_UPDATES_BEFORE_UPDATE` | Boolean, default `true` | Before manual interactive host/LXC/bulk updates, check whether a newer Forge `main` revision exists and ask whether to update Forge first. Set `false` in local `forge.conf` to disable. Scheduled and noninteractive runs never prompt or automatically self-update. |
| `EMAIL_NOTIFICATIONS` | Boolean; default `false` | Master switch for Proxmox root-mail notifications, independent of manual/scheduled policies. |
| `NOTIFY_MANUAL` | `none`, `errors` or `all`; default `errors` | Notifications for manual host, LXC and bulk updates. `errors` mails only `FAILED`/`PARTIAL`; `all` also mails `SUCCESS` (including all-skipped/no-selected); `none` disables. |
| `NOTIFY_SCHEDULED` | `none`, `errors` or `all`; default `all` | Same policy for `forge update scheduled`. Requires `EMAIL_NOTIFICATIONS=true` and an independently authorized scheduled update; never enables a timer or target selection. |
| `UPDATE_RUNNING_LXC` | Boolean: `true` or `false` | Include currently running LXCs in `forge lxc list-targets`, `forge lxc update all` and `forge update all`. It does not restrict `forge lxc update TARGET`. |
| `EXCLUDE` | Empty string or comma-separated VMIDs/exact LXC names | Remove matching running LXCs from automatic listing and both bulk update commands **before** preflight, backup or update. Case-sensitive; no partial or wildcard matching. Does not affect explicit `forge lxc update TARGET` or host updates. Entries for stopped or absent LXCs are inactive. Example: `EXCLUDE="108,share"`. |
| `UPDATE_LXC_OS` | Boolean: `true` or `false` | Run the LXC OS/package-manager stage. |
| `UPDATE_LXC_APPLICATION` | Boolean: `true` or `false` | Run the detected Community Scripts application updater. |
| `RUN_CUSTOM_SCRIPTS` | Boolean: `true` or `false` | Run local `scripts.d/<VMID>/*.sh` scripts. |
| `LXC_UPDATE_TEMP_CORES` | Integer 0–8192, default `0` | Temporarily raise an LXC's configured core limit to this minimum during its update; `0` disables this adjustment. |
| `LXC_UPDATE_TEMP_MEMORY_MB` | Integer 0–1048576, default `0` | Temporarily raise an LXC's configured RAM limit to this minimum in MiB; `0` disables this adjustment. |
| `CUSTOM_SCRIPTS_DIR` | Absolute path | Absolute directory containing per-target custom scripts. |
| `CREATE_BACKUP_BEFORE_HOST_UPDATE` | Boolean: `true` or `false` | Create and validate a host configuration backup before host package changes. |
| `HOST_BACKUP_EXTRA_PATHS` | Empty string or comma-separated absolute paths | Optional paths appended to the fixed host-backup path set. Example: `/opt/custom,/srv/config`. |
| `CREATE_BACKUP_BEFORE_LXC_UPDATE` | Boolean: `true` or `false` | Must be `true` for LXC updates; create a same-run Proxmox recovery backup before mutation. |
| `ROLLBACK_ON_FAILURE` | Boolean: `true` or `false` | Attempt same-run guest recovery after eligible update/health failures. |
| `HEALTH_CHECK` | Boolean: `true` or `false` | Verify target health after mutation, including optional functional scripts. |
| `HEALTH_SCRIPTS_DIR` | Absolute path | Directory containing optional `<VMID>/*.sh` guest functional checks (default `/opt/proxmox-forge/health.d`). Missing per-target directory means generic health checks only. |
| `MIN_ROOT_FREE_MB` | Integer from 1 to 1048576, default 1024 | Minimum free space on `/` before updating host or LXC. |
| `MIN_MEM_AVAILABLE_MB` | Integer from 1 to 1048576, default 128 | Minimum `MemAvailable` in MiB before host or LXC updates; fail closed when unavailable. |
| `LOG_DIR` | Absolute path | Base Forge log directory. |
| `LOG_KEEP` | Positive integer (`>= 1`) | Number of timestamped logs retained independently per LXC, per-run logs and each host `common`/`error` log stream (active file included). |
