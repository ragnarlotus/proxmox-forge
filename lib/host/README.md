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
→ success
```

APT runs non-interactively with configuration-file handling set to keep existing local configuration when package defaults differ.

Forge does **not** reboot the Proxmox host automatically. A newly installed kernel therefore becomes active only after a separately controlled reboot.
