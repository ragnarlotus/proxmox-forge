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

Forge does **not** reboot the Proxmox host automatically. After successful updates, `reboot_required=yes|no|unknown` is reported. Detection checks Debian's `/run/reboot-required` marker and compares the running kernel to newer `/boot/vmlinuz-*-pve` kernel images using Debian version ordering. `unknown` means no kernel inventory was available and no marker requested reboot; `no` means no checked signal was found, **not** that every daemon has restarted. Kernel pinning may mean a reboot alone will not activate the newest installed kernel. Detection errors are warnings, not update failures.

## Explicitly held APT packages (F022)

After the host requirements check and before creating a backup or updating packages, Forge runs read-only `apt-mark showhold`. It reports `held_package=<name> type=host` for each explicitly held package and `held_packages=<count> type=host` in terminal output and the run log. Packages held by the administrator remain held; Forge never uses `apt-mark unhold`. The detection step only reports explicit APT holds, not every potential dependency-related "kept back" upgrade. An inspection failure is logged as a warning and does not change the update's exit status.
