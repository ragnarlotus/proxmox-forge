# Forge custom scripts

Target-specific custom scripts live in this project-root directory under:

```text
scripts.d/<VMID>/
```

Forge executes only regular files whose names end exactly in `.sh` for one VMID after that LXC's normal OS/application update when `RUN_CUSTOM_SCRIPTS=true`.

Other files are ignored, including editor backup files such as `*.sh~`, Markdown documentation, and any other non-`.sh` content.

These scripts are target-specific extensions; they are not part of Forge's internal `lib/lxc/update/` implementation.

The actual target-specific scripts are local data and are intentionally ignored by Git. Only this README is versioned.
