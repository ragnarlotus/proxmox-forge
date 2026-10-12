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
- `CUSTOM_SCRIPTS_DIR`, `HEALTH_SCRIPTS_DIR` and `LOG_DIR` must be absolute paths;
- each non-empty `HOST_BACKUP_EXTRA_PATHS` entry must be an absolute path;
- `EXCLUDE` must be empty or comma-separated exact VMIDs/hostnames. Spaces around entries are accepted; empty entries, wildcards and spaces inside names are rejected;
- `LOG_KEEP` must be a positive integer;
- `MIN_ROOT_FREE_MB` and `MIN_MEM_AVAILABLE_MB` must each be integers from 1 to 1048576 MiB.

Run `forge show-config` to print the validated effective settings (defaults merged with local overrides) in alphabetical order. Each line is a shell-escaped `KEY=value` assignment followed by `# source=default` or `# source=override`. An override is marked even if it repeats the default value. Sensitive-looking keys (passwords, tokens, secrets and credentials) are redacted. This read-only command does not query Proxmox guest state or run the `validate-config` LXC recovery-policy preflight; it only validates configuration syntax and values.

Because `forge.conf` is Git-ignored, normal `git pull --ff-only` updates do not replace local overrides. Target-specific contents below `scripts.d/` and `health.d/` are also ignored except for their README files.

## Current configuration keys

LXC requirements checks are mandatory before backup or mutation and cannot be disabled. `forge validate-config` additionally checks backup-policy and persistent-snapshot compatibility for the running LXCs in automatic update scope. Both bulk and explicit LXC updates run the same read-only conflict check before any update begins. Stopped LXCs are checked only when explicitly selected. With `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true`, snapshot-incompatible selected LXCs are allowed only when the recovery backup is enabled and no persistent snapshots would be destroyed. `validate-config` does not modify containers.

| Key | Type / accepted value | Purpose |
| --- | --- | --- |
| `UPDATE_HOST` | Boolean: `true` or `false` | Enable local Proxmox host updates. |
| `UPDATE_RUNNING_LXC` | Boolean: `true` or `false` | Include currently running LXCs in `forge lxc list-targets`, `forge lxc update all` and `forge update all`. It does not restrict `forge lxc update TARGET`. |
| `EXCLUDE` | Empty string or comma-separated VMIDs/exact LXC names | Remove matching running LXCs from automatic listing and both bulk update commands **before** preflight, backup or update. Case-sensitive; no partial or wildcard matching. Does not affect explicit `forge lxc update TARGET` or host updates. Entries for stopped or absent LXCs are inactive. Example: `EXCLUDE="108,share"`. |
| `UPDATE_LXC_OS` | Boolean: `true` or `false` | Run the LXC OS/package-manager stage. |
| `UPDATE_LXC_APPLICATION` | Boolean: `true` or `false` | Run the detected Community Scripts application updater. |
| `RUN_CUSTOM_SCRIPTS` | Boolean: `true` or `false` | Run local `scripts.d/<VMID>/*.sh` scripts. |
| `CUSTOM_SCRIPTS_DIR` | Absolute path | Absolute directory containing per-target custom scripts. |
| `CREATE_BACKUP_BEFORE_HOST_UPDATE` | Boolean: `true` or `false` | Create and validate a host configuration backup before host package changes. |
| `HOST_BACKUP_EXTRA_PATHS` | Empty string or comma-separated absolute paths | Optional paths appended to the fixed host-backup path set. Example: `/opt/custom,/srv/config`. |
| `CREATE_BACKUP_BEFORE_LXC_UPDATE` | Boolean: `true` or `false` | Create a Proxmox recovery backup before LXC mutation. |
| `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE` | Boolean: `true` or `false` | Default `true`; when safe, use the same-run `vzdump` backup instead of a persistent snapshot for unsupported LXCs. Set `false` to require persistent snapshots and block snapshot-incompatible targets. |
| `ROLLBACK_ON_FAILURE` | Boolean: `true` or `false` | Attempt same-run guest recovery after eligible update/health failures. |
| `HEALTH_CHECK` | Boolean: `true` or `false` | Verify target health after mutation, including optional functional scripts. |
| `HEALTH_SCRIPTS_DIR` | Absolute path | Directory containing optional `<VMID>/*.sh` guest functional checks (default `/opt/proxmox-forge/health.d`). Missing per-target directory means generic health checks only. |
| `MIN_ROOT_FREE_MB` | Integer from 1 to 1048576, default 1024 | Minimum free space on `/` before updating host or LXC. |
| `MIN_MEM_AVAILABLE_MB` | Integer from 1 to 1048576, default 128 | Minimum `MemAvailable` in MiB before host or LXC updates; fail closed when unavailable. |
| `LOG_DIR` | Absolute path | Base Forge log directory. |
| `LOG_KEEP` | Positive integer (`>= 1`) | Number of timestamped logs retained per LXC. |
