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
