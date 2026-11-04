# Host update workflow


The current host workflow is:

```text
validate configuration
→ host requirements
→ host configuration backup
→ apt-get update
→ apt-get full-upgrade
→ apt-get autoremove
→ post-update host requirements/health
→ detect reboot indication and newer installed PVE kernel
→ success (report status; no automatic reboot)
```

APT runs non-interactively with configuration-file handling set to keep existing local configuration when package defaults differ.

Forge does **not** reboot the Proxmox host automatically. After successful updates, `reboot_required=yes|no|unknown` is reported. Detection checks Debian's `/run/reboot-required` marker and compares the running kernel to newer `/boot/vmlinuz-*-pve` kernel images using Debian version ordering. `unknown` means no kernel inventory was available and no marker requested reboot; `no` means no checked signal was found, **not** that every daemon has restarted. Kernel pinning may mean a reboot alone will not activate the newest installed kernel. Detection errors are warnings, not update failures. When F094 positively identifies a newer installed Proxmox kernel than the one running, the final host `Result` cell also includes an actionable reboot warning. It appears in individual and combined final tables without changing `SUCCESS`, triggering a reboot, or confusing a generic Debian reboot marker with a kernel upgrade.

## Held packages with available upgrades (F022)

After the host APT update stage (successful or failed), Forge checks `apt-mark showhold` and, for each held package, compares `apt-cache policy`'s installed and candidate versions using `dpkg --compare-versions`. It warns **only** when newer candidates exist, and records their names and versions in the update log. Holds with no newer candidates are not reported. After a successful `apt-get update`, this uses refreshed package lists. If updating the APT indexes failed, available version information may be stale. Forge does not unhold anything, claim to have installed a held upgrade, or change the original update/recovery result. A detection failure is a nonfatal warning, never interpreted as zero pending holds.

F220: completed individual host runs emit one structured `result_target` record with the target and authoritative result. Combined bulk runs suppress the nested host record; the coordinator emits it instead.

F221: a read-only pre/post dpkg comparison adds `apt_upgraded=N|-` to the final result. The host never rolls back; partial upgrades persist and are counted if verifiable. Measurement failures do not affect the update exit code.

The host `Software version` cell reports Proxmox VE's installed pve-manager version, Debian's VERSION_ID and the running Proxmox kernel, plus the latest installed PVE kernel when it differs. The facts come from `pveversion`, `/etc/os-release`, `uname -r` and F094's existing kernel inventory; unavailable facts stay unknown. They are read only, recorded in the authoritative escaped `host_platform` field and carried through bulk results without changing update execution or reboot policy.
