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
- `CUSTOM_SCRIPTS_DIR` and `LOG_DIR` must be absolute paths;
- each non-empty `HOST_BACKUP_EXTRA_PATHS` entry must be an absolute path;
- `LOG_KEEP` must be a positive integer.

Because `forge.conf` is Git-ignored, normal `git pull --ff-only` updates do not replace local overrides. Target-specific contents below `scripts.d/` are also ignored except for `scripts.d/README.md`.

## Current configuration keys

LXC requirements checks are mandatory before backup or mutation and cannot be disabled. `forge validate-config` additionally checks backup-policy and persistent-snapshot compatibility for the running LXCs in automatic update scope. Both bulk and explicit LXC updates run the same read-only conflict check before any update begins. Stopped LXCs are checked only when explicitly selected. With `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true`, snapshot-incompatible selected LXCs are allowed only when the recovery backup is enabled and no persistent snapshots would be destroyed. `validate-config` does not modify containers.

| Key | Type / accepted value | Purpose |
| --- | --- | --- |
| `UPDATE_HOST` | Boolean: `true` or `false` | Enable local Proxmox host updates. |
| `UPDATE_RUNNING_LXC` | Boolean: `true` or `false` | Include currently running LXCs in `forge lxc list-targets`, `forge lxc update all` and `forge update all`. It does not restrict `forge lxc update TARGET`. |
| `UPDATE_LXC_OS` | Boolean: `true` or `false` | Run the LXC OS/package-manager stage. |
| `UPDATE_LXC_APPLICATION` | Boolean: `true` or `false` | Run the detected Community Scripts application updater. |
| `RUN_CUSTOM_SCRIPTS` | Boolean: `true` or `false` | Run local `scripts.d/<VMID>/*.sh` scripts. |
| `CUSTOM_SCRIPTS_DIR` | Absolute path | Absolute directory containing per-target custom scripts. |
| `CREATE_BACKUP_BEFORE_HOST_UPDATE` | Boolean: `true` or `false` | Create and validate a host configuration backup before host package changes. |
| `HOST_BACKUP_EXTRA_PATHS` | Empty string or comma-separated absolute paths | Optional paths appended to the fixed host-backup path set. Example: `/opt/custom,/srv/config`. |
| `CREATE_BACKUP_BEFORE_LXC_UPDATE` | Boolean: `true` or `false` | Create a Proxmox recovery backup before LXC mutation. |
| `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE` | Boolean: `true` or `false` | Default `true`; when safe, use the same-run `vzdump` backup instead of a persistent snapshot for unsupported LXCs. Set `false` to require persistent snapshots and block snapshot-incompatible targets. |
| `ROLLBACK_ON_FAILURE` | Boolean: `true` or `false` | Attempt same-run guest recovery after eligible update/health failures. |
| `HEALTH_CHECK` | Boolean: `true` or `false` | Verify target health after mutation. |
| `LOG_DIR` | Absolute path | Base Forge log directory. |
| `LOG_KEEP` | Positive integer (`>= 1`) | Number of timestamped logs retained per LXC. |
