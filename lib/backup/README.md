# Backup and recovery

## Host configuration backup

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
/opt/proxmox-forge/scripts.d/
/opt/proxmox-forge/health.d/
```

When present, the optional host-local `/opt/proxmox-forge/forge.conf` is also included automatically. Forge's versioned source files are not included by default and should be restored from Git.

`HOST_BACKUP_EXTRA_PATHS` may append host-local files or directories to this set without replacing the mandatory paths. Its value is a comma-separated list of absolute paths, for example:

```bash
HOST_BACKUP_EXTRA_PATHS="/opt/custom,/srv/config"
```

Every configured additional path must exist when the backup is created; a missing configured path makes the backup fail rather than being silently omitted.

Forge verifies that the archive exists, is non-empty and can be listed by `tar` before the update proceeds. Forge-created host configuration archives older than 14 days are removed after a new archive has been validated.

Host failures are reported as failures with `rollback=unsupported`; Forge never pretends that LXC restore semantics apply to the Proxmox host.

## Restoring a Proxmox VE host

To restore a PVE host from a Forge host backup after a rebuild, first install Proxmox VE, then install/clone Proxmox Forge on the new host and run:

```bash
cd /opt/proxmox-forge
bash lib/backup/host/restore.sh
```

The restore script then guides the remaining PVE recovery process. The **Forge configuration and custom scripts** restore subject copies the saved `forge.conf` (if present in the archive), `scripts.d/` and `health.d/` back into `/opt/proxmox-forge/` after cloning Forge. For path-based restore subjects, the summary marks a subject as skipped when none of its paths exist in the archive, and warns about individual absent paths when at least one path was restored. This is a manual recovery procedure, not automatic host rollback. It is the only `lib/` script intended to be started directly and it participates in the same global Forge execution lock.

## LXC backup and recovery semantics

Forge does not maintain a second, competing LXC backup policy. Proxmox remains authoritative.

For each LXC, Forge reads enabled Proxmox backup jobs and requires exactly one applicable job. It builds a one-target `vzdump` command from the job options exposed by the installed `vzdump` CLI, including the configured storage and applicable backup behaviour.

The important guarantees are:

- `vzdump` runs synchronously and its exit status is authoritative;
- the exact newly created recovery volume is identified by comparing backup volumes before and after `vzdump`;
- backup creation is limited to creating and identifying the recovery artifact; guest health is validated later by the update workflow;
- the exact recovery artifact is retained for possible same-run rollback;
- Forge does not implement a separate LXC backup-retention system; applicable Proxmox job options remain authoritative.

Forge also creates a persistent LXC snapshot named `Update_*` immediately before mutating stages. Its retention limit is derived from the `keep-last` rule of the single applicable enabled Proxmox backup job: when the limit is reached, only the oldest `Update_*` snapshots are pruned **before** creating the next snapshot. Snapshots with other names are never pruned by Forge. The new snapshot is retained after success. The backup job must specify a positive `keep-last` value; missing/unsupported retention or failed snapshot creation aborts before updating packages or applications.

If a required OS, application, custom-script or health stage fails and `ROLLBACK_ON_FAILURE=true`, Forge runs `pct rollback` to the exact persistent snapshot created for that run. After restarting the guest, it waits for `pct exec` readiness and reuses the normal LXC health check before reporting recovery success. For snapshot-capable LXCs, Forge does not use destructive `pct restore --force` automatically. Their `vzdump` backup remains available for manual recovery. When `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true` and the centralized preflight authorizes it, a snapshot-incompatible LXC instead uses its newly created `vzdump` backup for recovery through the existing advanced restore helper. The helper verifies that no persistent snapshots can be destroyed immediately before `pct restore --force`; a conflicting snapshot blocks the restore. External bind-mount data is excluded from both snapshot and backup recovery.

Recovery success does **not** convert the original update failure into success. The target remains failed, preserving the primary result, and either bulk update command may continue with later targets. For an explicitly selected LXC that was originally stopped, Forge also attempts to restore that stopped state after success or failure/recovery.

## Snapshot eligibility, mount points and external data

Forge determines whether a given LXC supports a **persistent Proxmox snapshot** by querying the installed Proxmox API (`/nodes/<node>/lxc/<VMID>/feature` with `feature=snapshot`). It does **not** assume that every mount point makes snapshots impossible:

- A Proxmox-defined `mp0`, `mp1`, etc. can refer either to a storage-managed volume or to a host-directory bind mount. Snapshot eligibility depends on the actual mount/storage configuration. A `backup=0` option does not make a non-snapshot-capable mount snapshot-capable.
- A low-level `lxc.mount.entry` bind is outside Proxmox's managed mount-point definitions. Proxmox may still report `hasFeature=1` for the guest's managed storage; the externally mounted files are **not** included in that rootfs snapshot. A successful snapshot or rollback therefore says nothing about the contents of the external path.

Observed on the Proxmox host on 2026-10-12: LXCs **111 (share), 113 (soulsync), 117 (soultomasz)** have host-path `mp0` bindings and report `hasFeature=0`; **102 (plex)** has multiple external `lxc.mount.entry` bindings and reports `hasFeature=1`. This is a description of that verified configuration, not a rule based solely on the presence of the `mp0` key.

When `hasFeature=1`, Forge uses its new same-run `Update_*` snapshot for automatic rollback. When `hasFeature=0`, Forge permits backup-only recovery **only** if `BACKUP_WHEN_SNAPSHOT_NOT_POSIBLE=true`, backup creation is enabled, the rootfs is storage-backed, an applicable backup policy exists, and no persistent snapshots would be lost. In both cases, a normal mutating update creates a fresh `vzdump` backup if enabled. The `validate-config` message `will use the existing vzdump backup for recovery` identifies the planned recovery **method**, not a backup already made by validation; the wording is imprecise. `validate-config` examines only selected running LXCs, so stopped 113 and 117 do not appear in its automatic-scope output.

**External bind-mounted data is outside the rollback boundary:** neither a snapshot of the LXC's managed storage nor the LXC's `vzdump` backup restores changes to those host paths. Their data needs a separate backup if recovery is required.

## Filesystem trim vs backup retention

These are separate operations:

- **`pct fstrim`** reclaims unused guest filesystem blocks from the underlying storage where supported;
- **Proxmox backup prune/retention** removes old backup archives according to backup policy;
- **Forge host configuration backup retention** removes Forge-created host configuration archives older than 14 days.

Running `fstrim` after an update does not delete backup archives and is not a replacement for backup retention.
