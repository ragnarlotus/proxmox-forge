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

The `/var/lib/pve-cluster/config.db` member is captured through SQLite's online
backup API, not by reading the live database file with `tar`. This includes
committed transactions still in the SQLite WAL and creates a consistent,
integrity-checked standalone `config.db` without stopping `pve-cluster`.
The live `config.db`, `config.db-wal`, `config.db-shm`, and
`config.db-journal` files are excluded from direct archiving; the snapshot
is placed at the same archive path used by the existing restore tool. Failure
to snapshot or validate the database prevents host updates.

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

## LXC recovery policy

Forge updates running LXCs in automatic scopes; an explicitly selected stopped
LXC is temporarily started for its update and returned to the stopped state
after the update or recovery attempt. Backups and rollback are governed by the
same rules in either case.



Forge does not maintain a second, competing LXC backup policy. Proxmox remains authoritative.

For each selected LXC, Forge reads enabled Proxmox backup jobs and requires exactly one applicable job. It builds a one-target `vzdump` command from the job options exposed by the installed `vzdump` CLI. Proxmox remains authoritative for backup storage, mode, compression and retention.

The important guarantees are:

- `vzdump` runs synchronously and its exit status is authoritative;
- the exact newly created recovery volume is identified from `vzdump`'s reported archive path and validated against `pvesm path` for the new volumes; this remains unambiguous if another backup job creates an archive while Forge awaits Proxmox's global backup lock. Backends that do not expose a local archive path must still yield exactly one new volume, or Forge stops safely;
- backup creation is limited to creating and identifying the recovery artifact; guest health is validated later by the update workflow;
- the exact recovery artifact is retained for possible same-run rollback;
- Forge does not implement a separate LXC backup-retention system; applicable Proxmox job options remain authoritative.

Forge no longer creates, prunes or rolls back persistent `Update_*` snapshots.
The applicable backup job supplies the archive mode and retention. A `vzdump`
job with `mode=snapshot` creates a **temporary** source-volume snapshot and
cleans it up when the backup finishes; the archive is stored on the job's
configured backup storage.

When an OS, application, custom-script or health stage fails and
`ROLLBACK_ON_FAILURE=true`, Forge uses **only** the exact newly created
`vzdump` archive for automatic guest recovery. The guarded restore helper
uses `pct restore --force`, preserves excluded storage-backed mount volumes,
rechecks snapshot absence and restarts/revalidates the guest. A restored guest
still reports its original failed update; succeeding at recovery never changes
the primary exit status. Initially stopped explicitly selected guests are
returned to stopped after the update/recovery attempt.

For safe automatic restore, the preflight requires exactly one applicable
enabled Proxmox backup job, `CREATE_BACKUP_BEFORE_LXC_UPDATE=true`, a
storage-backed rootfs, and **no existing persistent LXC snapshots**. The
`/nodes/<node>/lxc/<VMID>/feature` snapshot-capability API is no longer
consulted. Existing `Update_*` or manually named snapshots are never deleted
by Forge; if they exist and automatic recovery is enabled, preflight stops the
update rather than risk destroying them. Review and remove old snapshots
**manually** only after verifying your independent backup. Disabling
`ROLLBACK_ON_FAILURE` skips the automatic-restore safety check but still
requires an independent backup before mutation. An existing restore-time
snapshot conflict always blocks forced restore.

**External bind-mounted data is outside the rollback boundary:** neither a snapshot of the LXC's managed storage nor the LXC's `vzdump` backup restores changes to those host paths. Their data needs a separate backup if recovery is required.

## Filesystem trim vs backup retention

These are separate operations:

- **`pct fstrim`** reclaims unused guest filesystem blocks from the underlying storage where supported;
- **Proxmox backup prune/retention** removes old backup archives according to backup policy;
- **Forge host configuration backup retention** removes Forge-created host configuration archives older than 14 days.

Running `fstrim` after an update does not delete backup archives and is not a replacement for backup retention.
