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

## Held packages with available upgrades (F022)

After the host APT update stage (successful or failed), Forge checks `apt-mark showhold` and, for each held package, compares `apt-cache policy`'s installed and candidate versions using `dpkg --compare-versions`. It warns **only** when newer candidates exist, and records their names and versions in the update log. Holds with no newer candidates are not reported. After a successful `apt-get update`, this uses refreshed package lists. If updating the APT indexes failed, available version information may be stale. Forge does not unhold anything, claim to have installed a held upgrade, or change the original update/recovery result. A detection failure is a nonfatal warning, never interpreted as zero pending holds.


## Final notification draft (F157)

After an individual host update, Forge displays one reusable plain-text notification preview with subject, SUCCESS/FAILED status, hostname and either required restart status or the failing stage and exit code. It does **not** send email yet. When the host is being updated within a bulk run, only the bulk notification is shown. This presentation never changes the original update result.
