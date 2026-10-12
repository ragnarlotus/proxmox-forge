# Forge functional health checks

Optional, per-target checks live in `health.d/<VMID>/*.sh` on the Proxmox host.

- The default path is `/opt/proxmox-forge/health.d`; `HEALTH_SCRIPTS_DIR` can override it.
- Only regular, non-symlink `.sh` files in the matching VMID directory run, in filename order. Other content is ignored.
- Scripts are streamed to `pct exec <VMID> -- bash -s --` and run **inside the guest**; no copy is installed.
- They run after Forge's generic running/systemd checks when a health stage is performed, including the health check after automatic rollback.
- Missing or empty directories add no functional checks. `HEALTH_CHECK=false` disables the normal post-update health stage.
- Exit status 0 means healthy; nonzero fails the target and can trigger the existing recovery policy. Processing stops at the first failed check.
- Scripts should perform **only read-only checks**, but arbitrary Bash scripts are not sandboxed: operators must review scripts for safety. Avoid writes, restarts, upgrades, and unbounded waits. When using `curl`, set `--max-time` and `--fail`.
- Files are host-local and Git-ignored. They are included in Forge host configuration backups and host-restore subject 5.

Example: `health.d/102/01-web.sh` can perform a private, authenticated or unauthenticated HTTP health request specific to Plex; endpoint/credentials should be chosen and protected for that deployment. No example is executed automatically.

Only this README is versioned.
